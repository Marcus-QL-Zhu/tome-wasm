// Test-only real Wasm RPC. No network, production database, or player save.
import {readFile,writeFile,mkdir} from 'node:fs/promises';
import {resolve,dirname} from 'node:path';
import {pathToFileURL} from 'node:url';
const root=resolve(process.argv[2]),out=resolve(process.argv[3]);
await mkdir(dirname(out),{recursive:true});
const {createKernel}=await import(pathToFileURL(resolve(root,'kernel_runtime.mjs')));
const {installEncounter}=await import(pathToFileURL(resolve(root,'encounter_overlay.mjs')));
const {default:createTome}=await import(pathToFileURL(resolve(root,'tome.js')));
const data=await readFile(resolve(root,'tome.data')),wasmBinary=await readFile(resolve(root,'tome.wasm'));
const party=['184917','159442','425367'].map((template,i)=>({template,campaign_identity:{person_id:'party-'+i,origin:'isolated-probe'}}));
const enemies=Array.from({length:5},(_,i)=>({prototype:'orc warrior',kind:'rare',class:['Bulwark','Berserker','Archmage','Bulwark','Berserker'][i],level:15,hp_multiplier:1}));
const manifest={format:'tome-encounter-v1',seed:41,party,enemies,map:{kind:'forest',size:64},zone:{template:'old-forest',reference_level:14,floor_count:1}};
const logs=[],report={runtime:'real Wasm',fixture_controlled:true,production_access:false,steps:[],passed:false};
async function make(){return createKernel(createTome,{wasmBinary,getPreloadedPackage:()=>data.buffer.slice(data.byteOffset,data.byteOffset+data.byteLength)},{log:(...x)=>logs.push(x.join(' ')),prepare:async m=>{
 installEncounter(m,manifest);
 m.FS.writeFile('/bundle/headless/equipment_slots_fixture.lua',await readFile('tests/tome_equipment_slots_fixture.lua','utf8'));
 const p='/bundle/headless/worker.lua';let s=m.FS.readFile(p,{encoding:'utf8'});const marker="    elseif req.method=='capabilities' then";
 if(!s.includes(marker))throw Error('missing fixture RPC insertion');
 s=s.replace(marker,"    elseif req.method=='fixture_slots' then\n        last_id=id\n        local ok,result=xpcall(function()return require('equipment_slots_fixture').run(state,req.params.phase) end,debug.traceback)\n        if ok then reply(id,result) else print(tostring(result));reject(id,'fixture_failed') end\n"+marker);m.FS.writeFile(p,s);
 }});}

const {normalizePartitionExport,selectPartitions,verifyAuthorizedPartitions}=await import(pathToFileURL(resolve(root,'partition_transport.mjs')));

const identity=JSON.parse(await readFile(resolve(root,'../identity.json'),'utf8'));
const scope={build:identity.build_id,world_id:'probe-world',campaign_id:'probe-campaign'};
const members=['party-0','party-1','party-2'];
let a,b;
async function checkpoint(engine,g,parent=null){
 const raw=await engine.rpc('partition_export',{protected_by_owner:{}},g);
 return normalizePartitionExport(scope,parent,raw,g);
}
async function rehydrate(candidate){
 const m=candidate.manifest;
 const ids=['hot',...m.partitions.map(p=>p.partition_id)];
 const entries={hot:m.hot_root,...Object.fromEntries(m.partitions.map(p=>[p.partition_id,p]))};
 const blobs=Object.fromEntries(ids.map(id=>[id,candidate.blobs[entries[id].blob_digest]]));
 const engine=await make();
 const result=await engine.rpc('partition_import',{manifest:m,blobs:await verifyAuthorizedPartitions(m,scope,ids,blobs)});
 return [engine,result.generation];
}
try{
 a=await make();
 let {generation:g}=await a.rpc('create',{seed:41,fixture:'formal'});
 await a.rpc('fixture_slots',{phase:'setup'},g);
 await a.rpc('partition_enable',{},g);
 if(process.argv.includes('--seed')){
  const seed=await a.rpc('fixture_slots',{phase:'demon_seed'},g);
  const snapshot=await checkpoint(a,g);
  [b,g]=await rehydrate(snapshot);
  const restored=await b.rpc('fixture_slots',{phase:'demon_restore'},g);
  if(['uid','demon','name','life','level'].some(key=>seed[key]!==restored[key]))throw Error('demon seed changed after reload');
  const summoned=await b.rpc('fixture_slots',{phase:'demon_summon'},g);
  if(summoned.demon!==seed.demon)throw Error('summoned a different demon');
  report.passed=true;report.steps=[seed,restored,summoned];
 }else{
 await a.rpc('dm_transition',{operation:'area_depart',area:{world_clock:{world_tick:0,day_in_quarter:0}}},g);
 const checkpoint0=await checkpoint(a,g);
 [b,g]=await rehydrate(checkpoint0);
 const part=await b.rpc('fixture_slots',{phase:'socket_setup'},g);
 await b.rpc('fixture_slots',{phase:'drop_socket'},g);
 const saved=await checkpoint(b,g,checkpoint0.manifest);
 b.dispose();b=null;[b,g]=await rehydrate({manifest:saved.manifest,blobs:{...checkpoint0.blobs,...saved.blobs}});
 await b.rpc('fixture_slots',{phase:'recover_socket'},g);
 const restored=await b.rpc('fixture_slots',{phase:'socket_restore'},g);
 if(restored.uid!==part.uid)throw Error('attachment changed after reload');
 report.passed=true;report.steps=[part,restored];
 }

}catch(e){report.error=String(e.stack||e);process.exitCode=1;}
finally{
 a?.dispose();b?.dispose();report.logs=logs.slice(-180);
 await writeFile(out,JSON.stringify(report,null,2));
 console.log(JSON.stringify({passed:report.passed,error:report.error,logs:logs.slice(-80)}));
}