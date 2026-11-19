import test from 'node:test';
import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {digest} from '../tome_mvp/wasm/battle_session.mjs';
import {createPartitionResident} from '../scripts/tome_partition_resident.mjs';
import {reconstructHotIndex} from '../tome_mvp/wasm/partition_session_host.mjs';
const sha=x=>createHash('sha256').update(x).digest('hex');
async function fixture(){
 const scope={build:'b',world_id:'w',campaign_id:'c'};
 const manifest={format:'tome-partitioned-native-v1',...scope,hot_root:{root_ref:'r:1',blob_digest:sha('hot'),strong_refs:[]},partitions:[],objects:{'r:1':{owner:'hot'}}};
 const envelope={native_boundary:'campaign_admin',final:'f'};
 const archive={format:'tome-partition-session-v1',build:'b',seed:1,base:{version:1,manifest_sha256:await digest(manifest),envelope},audit:[],events:[],final:'f'};
 return {kind:'prepare',scope,archive,manifest,blobs:{hot:'aG90'},selection:{kind:'loadout'},version:1,operations:[{operation:'campaign_items',world_id:'w',request:{operation:'equip'}},{operation:'campaign_reconcile',world_id:'w'}],delta_events:[],battle_id:'battle',request_id:'req',db_identity:{path:'p',instance_id:'i',device:1,inode:2}};
}
function setup(){
 let disposed=0,opened=0,operations=0;
 const native={local_areas:{outside:true}};
 const session={nativeBoundary:'campaign_admin',events:[],bridge:{generation:1,boundary:'decision',snapshot:{area_outside:true,map_available:false,ai_status:'idle'},state:()=>({})}};
 const kernel={dispose(){disposed++},async rpc(name,args){if(name==='dm_inspect')return native;if(name==='partition_confirm')return {confirmed:true,version:args.new_version,manifest_sha256:args.new_manifest_sha256};throw Error(name)}};
 const makeCandidate=async({prior,priorAudit,nextVersion})=>{operations++;session.events.push({kind:'campaign_items'},{kind:'campaign_reconcile'});const envelope={native_boundary:'campaign_admin',final:'next'};return {candidate:{manifest:prior,blobs:{},native,archive:{format:'tome-partition-session-v1',build:'b',seed:1,base:{version:nextVersion,manifest_sha256:await digest(prior),envelope},audit:[...priorAudit,...session.events],events:[],final:'next'}},results:[{},{}]};};
 const c=createPartitionResident({identityBytes:Buffer.from('{"build_id":"b"}'),open:async()=>{opened++;return kernel},restore:async()=>session,makeCandidate});
 return {c,session,stats:()=>({disposed,opened,operations})};
}
test('confirm gates reuse and clears only confirmed events',async()=>{
 const x=setup(),r=await fixture(),first=await x.c.request(r);assert.equal(first.ok,true);assert.equal(x.session.events.length,2);
 const ack=await x.c.request({kind:'confirm',lease:first.lease});assert.equal(ack.confirmed,true);assert.equal(x.session.events.length,0);
 const second=await x.c.request({...r,archive:first.candidate.archive,version:2,request_id:'req2'});assert.equal(second.ok,true);assert.equal(second.candidate.archive.audit.length,4);assert.deepEqual(x.stats(),{disposed:0,opened:1,operations:2});
 await x.c.request({kind:'abort',pending_token:second.lease.pending_token});assert.equal(x.stats().disposed,1);
});
test('pending, mismatch, and replay fail closed',async()=>{
 for(const mutate of [r=>r.delta_events.push({}),r=>r.operations[0].request.operation='drop',r=>r.selection={kind:'area',area_id:'none',floor:1},r=>r.blobs.hot='YmFk']){
  const x=setup(),r=await fixture();mutate(r);assert.equal((await x.c.request(r)).ok,false);assert.equal(x.stats().operations,0);
 }
 const x=setup(),r=await fixture(),first=await x.c.request(r);assert.equal((await x.c.request(r)).ok,false);assert.equal(x.stats().disposed,1);
 assert.equal((await x.c.request({kind:'confirm',lease:first.lease})).ok,false);
});
test('altered lease or later baseline destroys VM',async()=>{
 const x=setup(),r=await fixture(),first=await x.c.request(r);const bad=structuredClone(first.lease);bad.hot_sha256='0'.repeat(64);assert.equal((await x.c.request({kind:'confirm',lease:bad})).ok,false);assert.equal(x.stats().disposed,1);
 const y=setup(),v=await y.c.request(r);await y.c.request({kind:'confirm',lease:v.lease});const next={...r,archive:v.candidate.archive,version:2,db_identity:{...r.db_identity,inode:3}};assert.equal((await y.c.request(next)).ok,false);assert.equal(y.stats().disposed,1);
});
test('compact misses reject before any native operation',async()=>{
 const bare=setup(),r=await fixture();assert.equal((await bare.c.request({kind:'prepare_hot',binding:{},archive:r.archive,operations:r.operations,request_id:'x'})).ok,false);assert.equal(bare.stats().operations,0);
 for(const field of ['version','manifest_sha256','hot_sha256','envelope_sha256','frozen_identity','scope','db_identity']){
  const x=setup(),first=await x.c.request(r);await x.c.request({kind:'confirm',lease:first.lease});const l=first.lease,binding={scope:l.scope,db_identity:l.db_identity,frozen_identity:l.frozen_identity,version:l.new_version,manifest_sha256:l.new_manifest_sha256,hot_sha256:l.hot_sha256,envelope_sha256:l.new_envelope_sha256};
  binding[field]=field==='version'?99:'bad';const result=await x.c.request({kind:'prepare_hot',binding,archive:first.candidate.archive,operations:r.operations,request_id:'x'});assert.equal(result.ok,false);assert.equal(x.stats().operations,1);assert.equal(x.stats().disposed,1);
 }
});
test('full confirm enables compact and second confirm advances the private parent',async()=>{
 const r=await fixture();r.manifest.next_ref=2;r.manifest.next_uid=1;r.manifest.objects['r:1'].kind='table';r.archive.base.manifest_sha256=await digest(r.manifest);
 const native={local_areas:{outside:true}},session={seed:1,partitionOnly:true,nativeBoundary:'campaign_admin',events:[],bridge:{generation:1,revision:0,epoch:0,reason:null,boundary:'decision',snapshot:{area_outside:true,map_available:false,ai_status:'idle'},state:()=>({})},async execute(kind,body){this.events.push({kind,body});return {status:200,transition:{accepted:true}};}};
 let calls=0;const kernel={dispose(){},async rpc(method,args){if(method==='dm_inspect')return native;if(method==='partition_confirm')return {confirmed:true,version:args.new_version,manifest_sha256:args.new_manifest_sha256};if(method==='partition_prepare'){calls++;return {pending_token:args.pending_token,format:'tome-partitioned-native-v1',generation:1,boundary:'decision',native_boundary:'campaign_admin',world_id:'w',campaign_id:'c',next_ref:2,next_uid:1,descriptors:[{partition_id:'hot',kind:'hot',root_ref:'r:1',strong_refs:[]}],dirty_blobs:[{partition_id:'hot',root_ref:'r:1',strong_refs:[],payload_base64:'aG90',bytes:3}],objects_delta:{format:'tome-hot-index-delta-v1',owner:'hot',records:{'r:1':{owner:'hot',kind:'table'}},retired:[]}};}throw Error(method)}};
 const c=createPartitionResident({identityBytes:Buffer.from('{"build_id":"b"}'),open:async()=>kernel,restore:async()=>session});
 const first=await c.request(r);assert.equal(first.ok,true,first.error);assert.equal((await c.request({kind:'confirm',lease:first.lease})).confirmed,true);
 const l=first.lease,binding={scope:l.scope,db_identity:l.db_identity,frozen_identity:l.frozen_identity,version:l.new_version,manifest_sha256:l.new_manifest_sha256,hot_sha256:l.hot_sha256,envelope_sha256:l.new_envelope_sha256};
 const second=await c.request({kind:'prepare_hot',binding,archive:first.candidate.archive,operations:r.operations,request_id:'second'});assert.equal(second.ok,true,second.error);assert.equal(second.warm_hit,true);assert.equal(second.candidate.manifest,undefined);assert.equal(second.candidate.archive.audit.length,4);assert.equal(second.lease.new_manifest_sha256,first.lease.new_manifest_sha256);assert.equal((await c.request({kind:'confirm',lease:second.lease})).confirmed,true);assert.equal(calls,2);
});
test('hot index delta preserves cold index and rejects invalid ownership, retirement and dependencies',()=>{
 const scope={build:'b',world_id:'w',campaign_id:'c'},prior={format:'tome-partitioned-native-v1',...scope,next_ref:5,next_uid:2,hot_root:{root_ref:'r:1',blob_digest:sha('hot'),strong_refs:[]},partitions:[{partition_id:'z',kind:'zone',area_id:'a',root_ref:'r:2',blob_digest:sha('cold'),strong_refs:['r:1']}],objects:{'r:1':{owner:'hot',kind:'table'},'r:2':{owner:'z',kind:'table'},'r:3':{owner:'hot',kind:'table'}}};
 const out={next_ref:6,next_uid:2,descriptors:[{partition_id:'hot',strong_refs:[]}],dirty_blobs:[{partition_id:'hot'}],objects_delta:{format:'tome-hot-index-delta-v1',owner:'hot',records:{'r:1':{owner:'hot',kind:'table'},'r:5':{owner:'hot',kind:'table'}},retired:['r:3']}};
 const result=reconstructHotIndex(prior,scope,out);assert.deepEqual(Object.keys(result.objects).sort(),['r:1','r:2','r:5']);assert.deepEqual(result.objects['r:2'],prior.objects['r:2']);
 for(const mutate of [x=>x.objects_delta.retired=[],x=>delete x.objects_delta.records['r:1'],x=>x.objects_delta.records['r:2']={owner:'hot',kind:'table'},x=>x.objects_delta.records['r:4']={owner:'hot',kind:'table'},x=>x.objects_delta.records['r:6']={owner:'hot',kind:'table'},x=>x.descriptors[0].strong_refs=['r:2'],x=>x.descriptors.push({partition_id:'z'}),x=>x.next_ref=4]){
  const bad=structuredClone(out);mutate(bad);assert.throws(()=>reconstructHotIndex(prior,scope,bad));
 }
});
