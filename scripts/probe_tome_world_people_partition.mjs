// Test-only real Wasm RPC. No network, production database, or player save.
import {readFile,writeFile,mkdir,readdir} from 'node:fs/promises';
import {resolve,dirname} from 'node:path';
import {pathToFileURL} from 'node:url';
const root=resolve(process.argv[2]||'artifacts/unified-battle-entry-20261117/kernel-r1/public');
const out=resolve(process.argv[3]||'artifacts/unified-battle-entry-20261117/native-partition-proof.json');
const {createKernel}=await import(pathToFileURL(resolve(root,'kernel_runtime.mjs')));
const {installEncounter}=await import(pathToFileURL(resolve(root,'encounter_overlay.mjs')));
const {installNativeZoneFixes}=await import(pathToFileURL(resolve(root,'native_zone_overlay.mjs')));
const {default:createTome}=await import(pathToFileURL(resolve(root,'tome.js')));
const data=await readFile(resolve(root,'tome.data')),wasmBinary=await readFile(resolve(root,'tome.wasm'));
const party=['184917','159442','425367'].map((template,i)=>({template,campaign_identity:{person_id:'party-'+i,origin:'isolated-probe'}}));
const enemies=Array.from({length:5},(_,i)=>({prototype:'orc warrior',kind:'rare',class:['Bulwark','Berserker','Archmage','Bulwark','Berserker'][i],level:15,hp_multiplier:1}));
const manifest={format:'tome-encounter-v1',seed:41,party,enemies,map:{kind:'forest',size:64},zone:{template:'old-forest',reference_level:14,floor_count:1}};
const logs=[],report={runtime:'real Wasm',fixture_controlled:true,production_access:false,steps:[],passed:false};
async function make(){return createKernel(createTome,{wasmBinary,getPreloadedPackage:()=>data.buffer.slice(data.byteOffset,data.byteOffset+data.byteLength)},{log:(...x)=>logs.push(x.join(' ')),prepare:async m=>{
 installEncounter(m,manifest);
 for(const n of ['worker','scene_placement','native_save_partition_scene','local_area','native_zone','dm_transition','campaign_transition','localization'])m.FS.writeFile('/bundle/headless/'+n+'.lua',await readFile('tome_mvp/headless/'+n+'.lua','utf8'));
 installNativeZoneFixes(m,{mission:true});
 m.FS.writeFile('/bundle/headless/named_people_fixture.lua',await readFile('tests/tome_world_people_partition_probe.lua','utf8'));
 const p='/bundle/headless/worker.lua';let s=m.FS.readFile(p,{encoding:'utf8'});const marker="    elseif req.method=='capabilities' then";
 if(!s.includes(marker))throw Error('missing fixture RPC insertion');
 s=s.replace(marker,"    elseif req.method=='fixture_named_people' then\n        last_id=id\n        local ok,result=xpcall(function()if req.params.phase=='victory_fixture'then terminal='victory';return {marked=true}end;return require('named_people_fixture').run(state,req.params)end,debug.traceback)\n        if ok then refresh_visibility();reply(id,result) else print(tostring(result));reject(id,'fixture_failed') end\n"+marker);m.FS.writeFile(p,s);
 }});}

const {normalizePartitionExport,selectPartitions,verifyAuthorizedPartitions}=await import(pathToFileURL(resolve(root,'partition_transport.mjs')));
const identity=JSON.parse(await readFile(resolve(root,'../identity.json'),'utf8'));
const scope={build:identity.build_id,world_id:'probe-world',campaign_id:'probe-campaign'};
let a,b,c;
try{
 a=await make();let r=await a.rpc('create',{seed:41,fixture:'formal'}),g=r.generation;
 const before=await a.rpc('fixture_named_people',{phase:'setup'},g);report.steps.push({setup:before});
 await a.rpc('partition_enable',{},g);
 let raw=await a.rpc('partition_export',{protected_by_owner:{}},g);
 let candidate=await normalizePartitionExport(scope,null,raw,g);
 const {EngineBridge}=await import(pathToFileURL(resolve(root,'engine_bridge.mjs')));
 const {digest}=await import(pathToFileURL(resolve(root,'battle_session.mjs')));
 const bridge=new EngineBridge(a.rpc);bridge.generation=g;bridge.caps=await a.rpc('capabilities',{});bridge.boundary='decision';await bridge.observe();
 const view=bridge.state();const envelope={generation:g,revision:bridge.revision,epoch:bridge.epoch,reason:bridge.reason,final:await digest(view),native_boundary:raw.native_boundary};
 const archive={format:'tome-partition-session-v1',build:scope.build,seed:41,base:{version:1,manifest_sha256:await digest(candidate.manifest),envelope},audit:[],events:[],final:envelope.final};
 await writeFile(resolve(dirname(out),'partition-base-candidate.json'),JSON.stringify({manifest:candidate.manifest,blobs:candidate.blobs,archive,view,native:await a.rpc('dm_inspect',{},g)}));
 const ids=selectPartitions(candidate.manifest,scope,{kind:'area',area_id:'area:probe-b',floor:1,sources:[{area_id:'area:probe-a',floor:1}]});
 const entries={hot:candidate.manifest.hot_root,...Object.fromEntries(candidate.manifest.partitions.map(p=>[p.partition_id,p]))};
 const blobs=Object.fromEntries(ids.map(id=>[id,candidate.blobs[entries[id].blob_digest]]));
 b=await make();r=await b.rpc('partition_import',{manifest:candidate.manifest,blobs:await verifyAuthorizedPartitions(candidate.manifest,scope,ids,blobs)});g=r.generation;
 const moved=await b.rpc('dm_transition',{operation:'spawn_enemy',operation_id:'cold-move',person_id:'probe-person',person_name:'Probe Person',placement:'same_room',source_area:'area:probe-a',source_floor:1},g);
 if(moved.accepted!==true||moved.transition?.status!=='applied')throw Error('cold actor move rejected');
 const checked=await b.rpc('fixture_named_people',{phase:'check'},g);report.steps.push({cold_transfer:checked,selected:ids});
 raw=await b.rpc('partition_export',{protected_by_owner:{}},g);
 const after=await normalizePartitionExport(scope,candidate.manifest,raw,g);
 const uid='e:'+before.uid;report.actor_owner=after.manifest.objects[uid]?.owner;
 if(report.actor_owner!=='hot')throw Error('named Actor did not remain hot');
 const all={...candidate.blobs,...after.blobs};const selected=selectPartitions(after.manifest,scope,{kind:'area',area_id:'area:probe-b',floor:1});
 const entries2={hot:after.manifest.hot_root,...Object.fromEntries(after.manifest.partitions.map(p=>[p.partition_id,p]))};
 const bodies=Object.fromEntries(selected.map(id=>[id,all[entries2[id].blob_digest]]));
 c=await make();r=await c.rpc('partition_import',{manifest:after.manifest,blobs:await verifyAuthorizedPartitions(after.manifest,scope,selected,bodies)});
 report.steps.push({second_restore:await c.rpc('fixture_named_people',{phase:'check'},r.generation)});
 report.steps.push({surrender_recovery:await c.rpc('fixture_named_people',{phase:'surrender'},r.generation)});
 await c.rpc('fixture_named_people',{phase:'victory_fixture'},r.generation);
 const again=await c.rpc('dm_transition',{operation:'spawn_enemy',operation_id:'after-victory',person_id:'probe-person',person_name:'Probe Person',placement:'same_room',source_area:'area:probe-b',source_floor:1},r.generation);
 const reopened=await c.rpc('observe',{},r.generation);if(again.transition?.status!=='applied'||reopened.status==='victory')throw Error('new encounter did not reopen cleared area');
 report.steps.push({cleared_area_reopened:true});
 report.passed=true;
}catch(e){report.error=String(e.stack||e);process.exitCode=1;}
finally{a?.dispose();b?.dispose();c?.dispose();report.logs=logs.slice(-35);await mkdir(dirname(out),{recursive:true});await writeFile(out,JSON.stringify(report,null,2));console.log(JSON.stringify({passed:report.passed,error:report.error,steps:report.steps.length,logs:logs.slice(-4)}));}
