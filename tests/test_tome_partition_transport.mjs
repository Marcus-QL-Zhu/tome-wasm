import test from 'node:test';import assert from 'node:assert/strict';import {createHash} from 'node:crypto';
import {selectPartitions,verifyAuthorizedPartitions} from '../tome_mvp/wasm/partition_transport.mjs';
const scope={build:'b',world_id:'w',campaign_id:'c'};
const hash=s=>createHash('sha256').update(s).digest('hex');
function fixture(){return {format:'tome-partitioned-native-v1',...scope,hot_root:{root_ref:'r:1',blob_digest:hash('hot'),strong_refs:[]},partitions:[{partition_id:'z',kind:'zone',area_id:'area:a',root_ref:'r:2',blob_digest:hash('zone'),strong_refs:[]},{partition_id:'l',kind:'level',area_id:'area:a',floor:1,root_ref:'r:3',blob_digest:hash('level'),strong_refs:['r:4']},{partition_id:'extra',kind:'zone',area_id:'area:b',root_ref:'r:4',blob_digest:hash('extra'),strong_refs:[]}],objects:{'r:1':{owner:'hot'},'r:2':{owner:'z'},'r:3':{owner:'l'},'r:4':{owner:'extra'}}};}
test('loadout prefetch reads hot and any real cold dependency',()=>{const m=fixture();assert.deepEqual(selectPartitions(m,scope,{kind:'loadout'}),['hot']);m.hot_root.strong_refs=['r:2'];assert.deepEqual(selectPartitions(m,scope,{kind:'loadout'}),['hot','z']);});
test('area selection resolves transitive owners from trusted manifest',()=>{const m=fixture();assert.deepEqual(selectPartitions(m,scope,{kind:'area',area_id:'area:a',floor:1}),['extra','hot','l','z']);assert.deepEqual(selectPartitions(m,scope,{kind:'area',area_id:'area:bad',floor:1}),['hot']);assert.deepEqual(selectPartitions(m,scope,{kind:'area',area_id:'area:a',floor:2}),['hot','z']);assert.throws(()=>selectPartitions(m,{...scope,build:'other'},{kind:'loadout'}),/scope/);});

test('named people prefetch their committed source level and reject missing sources',()=>{
 const m=fixture();m.partitions.push({partition_id:'source',kind:'level',area_id:'area:b',floor:1,root_ref:'r:5',blob_digest:hash('source'),strong_refs:[]});m.objects['r:5']={owner:'source'};
 assert.deepEqual(selectPartitions(m,scope,{kind:'area',area_id:'area:a',floor:1,sources:[{area_id:'area:b',floor:1}]}),['extra','hot','l','source','z']);
 assert.throws(()=>selectPartitions(m,scope,{kind:'loadout',sources:[{area_id:'area:missing',floor:1}]}),/not committed/);
 assert.throws(()=>selectPartitions(m,scope,{kind:'loadout',sources:[{area_id:'area:b',floor:true}]}),/invalid native person source/);
});
test('only exact selected data with matching SHA-256 is accepted',async()=>{const m=fixture();assert.deepEqual(await verifyAuthorizedPartitions(m,scope,['hot'],{hot:'aG90'}),[{partition_id:'hot',payload_base64:'aG90'}]);await assert.rejects(verifyAuthorizedPartitions(m,scope,['hot'],{hot:'YmFk'}),/digest/);await assert.rejects(verifyAuthorizedPartitions(m,scope,['hot'],{hot:'aG90',z:'eg=='}),/set/);await assert.rejects(verifyAuthorizedPartitions(m,scope,['hot'],{hot:'Zh=='}),/noncanonical/);});
test('multi-MiB valid blobs use bounded-stack decoding',async()=>{
 const m=fixture(),raw=Buffer.alloc(5*1024*1024,65),encoded=raw.toString('base64');
 m.hot_root.blob_digest=hash(raw);
 assert.deepEqual(await verifyAuthorizedPartitions(m,scope,['hot'],{hot:encoded}),[{partition_id:'hot',payload_base64:encoded}]);
 await assert.rejects(verifyAuthorizedPartitions(m,scope,['hot'],{hot:encoded.slice(0,100)+'='+encoded.slice(101)}),/invalid partition payload/);
});
test('versioned reader fails closed on changed manifest and reports cold bytes',async()=>{
 const {prepareAuthorizedPartitions}=await import('../tome_mvp/wasm/partition_transport.mjs');const m=fixture(),calls=[];
 const read=async ids=>{calls.push(ids);return {version:3,manifest:m,blobs:ids.length?{hot:'aG90'}:{}};};
 const p=await prepareAuthorizedPartitions(read,scope,{kind:'loadout'});assert.deepEqual(calls,[[],['hot']]);assert.equal(p.read_metrics.cold_bytes,0);assert.equal(p.read_metrics.bytes,3);
 let n=0;await assert.rejects(prepareAuthorizedPartitions(async ids=>({version:++n,manifest:m,blobs:{}}),scope,{kind:'loadout'}),/version changed/);
});
test('candidate export retains unloaded owners and refuses forged reuse',async()=>{
 const {normalizePartitionExport}=await import('../tome_mvp/wasm/partition_transport.mjs');const prior=fixture();
 const hot={partition_id:'hot',kind:'hot',root_ref:'r:1',strong_refs:[]};
 const out={format:'tome-partitioned-native-v1',generation:1,boundary:'decision',native_boundary:'decision',world_id:'w',campaign_id:'c',objects:structuredClone(prior.objects),next_ref:9,next_uid:9,descriptors:[hot],dirty_blobs:[{partition_id:'hot',root_ref:'r:1',strong_refs:[],payload_base64:'aG90',bytes:3}]};
 const value=await normalizePartitionExport(scope,prior,out,1);assert.equal(value.manifest.partitions.length,3);assert.deepEqual(value.blobs,{});
 const wrong=structuredClone(out);wrong.objects['r:2'].kind='class';await assert.rejects(normalizePartitionExport(scope,prior,wrong,1),/unloaded object metadata changed/);
 const move=structuredClone(out);move.objects['r:2'].owner='hot';await assert.rejects(normalizePartitionExport(scope,prior,move,1),/ownership change/);
 const bad=structuredClone(out);bad.dirty_blobs[0].bytes=4;await assert.rejects(normalizePartitionExport(scope,prior,bad,1),/size mismatch/);
});
test('unloaded strong references are passed to native exporter from trusted manifest',async()=>{
 const {protectedColdReferences,protectedReferencesByOwner}=await import('../tome_mvp/wasm/partition_transport.mjs');const m=fixture();
 assert.deepEqual(protectedColdReferences(m,scope,['hot']),['r:4']);
 assert.deepEqual(protectedColdReferences(m,scope,['hot','l']),['r:4']);
 assert.deepEqual(JSON.parse(JSON.stringify(protectedReferencesByOwner(m,scope,['hot','l']))),{z:[],l:['r:4'],extra:[]});
 assert.throws(()=>protectedColdReferences(m,scope,['hot','unauthorized']),/invalid resident/);
});
test('host export gets protected refs and rejects unstable state',async()=>{
 const {exportPartitionCandidate}=await import('../tome_mvp/wasm/partition_session_host.mjs');const prior=fixture();let requested;
 const out={format:'tome-partitioned-native-v1',generation:1,boundary:'decision',native_boundary:'campaign_admin',world_id:'w',campaign_id:'c',objects:structuredClone(prior.objects),next_ref:9,next_uid:9,descriptors:[{partition_id:'hot',kind:'hot',root_ref:'r:1',strong_refs:[]}],dirty_blobs:[{partition_id:'hot',root_ref:'r:1',strong_refs:[],payload_base64:'aG90',bytes:3}]};
 const session={suspended:true,bridge:{generation:1,boundary:'decision',snapshot:{},rpc:async(method,params)=>{requested={method,params};return out;}}};
 const candidate=await exportPartitionCandidate(session,scope,prior,['hot']);assert.deepEqual(JSON.parse(JSON.stringify(requested.params.protected_by_owner)),{z:[],l:['r:4'],extra:[]});assert.equal('protected_refs' in requested.params,false);assert.equal(candidate.native_boundary,'campaign_admin');
 session.bridge.pending=true;await assert.rejects(exportPartitionCandidate(session,scope,prior,['hot']),/stopped decision/);
});
