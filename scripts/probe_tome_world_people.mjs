// Test-only real Wasm RPC. No network, production database, or player save.
import {readFile,writeFile,mkdir,readdir} from 'node:fs/promises';
import {resolve,dirname} from 'node:path';
import {pathToFileURL} from 'node:url';
const root=resolve(process.argv[2]||'artifacts/unified-battle-entry-20261117/kernel-r1/public');
const out=resolve(process.argv[3]||'artifacts/unified-battle-entry-20261117/native-proof.json');
const {createKernel}=await import(pathToFileURL(resolve(root,'kernel_runtime.mjs')));
const {installEncounter}=await import(pathToFileURL(resolve(root,'encounter_overlay.mjs')));
const {installNativeZoneFixes}=await import(pathToFileURL(resolve(root,'native_zone_overlay.mjs')));
const {default:createTome}=await import(pathToFileURL(resolve(root,'tome.js')));
const data=await readFile(resolve(root,'tome.data')),wasmBinary=await readFile(resolve(root,'tome.wasm'));
const party=['184917','159442','425367'].map(template=>({template}));
const enemies=Array.from({length:5},(_,i)=>({prototype:'orc warrior',kind:'rare',class:['Bulwark','Berserker','Archmage','Bulwark','Berserker'][i],level:15,hp_multiplier:1}));
const manifest={format:'tome-encounter-v1',seed:41,party,enemies,map:{kind:'forest',size:64},zone:{template:'old-forest',reference_level:14,floor_count:1}};
const logs=[],report={runtime:'real Wasm',fixture_controlled:true,production_access:false,steps:[],passed:false};
async function make(){return createKernel(createTome,{wasmBinary,getPreloadedPackage:()=>data.buffer.slice(data.byteOffset,data.byteOffset+data.byteLength)},{log:(...x)=>logs.push(x.join(' ')),prepare:async m=>{
 installEncounter(m,manifest);
 for(const n of ['worker','scene_placement','native_save_partition_scene','local_area','native_zone','dm_transition','campaign_transition','localization'])m.FS.writeFile('/bundle/headless/'+n+'.lua',await readFile('tome_mvp/headless/'+n+'.lua','utf8'));
 installNativeZoneFixes(m,{mission:true});
 m.FS.writeFile('/bundle/headless/named_people_fixture.lua',await readFile('tests/tome_named_people_probe.lua','utf8'));
 const p='/bundle/headless/worker.lua';let s=m.FS.readFile(p,{encoding:'utf8'});const marker="    elseif req.method=='capabilities' then";
 if(!s.includes(marker))throw Error('missing fixture RPC insertion');
 s=s.replace(marker,"    elseif req.method=='fixture_named_people' then\n        last_id=id\n        local ok,result=xpcall(function()return require('named_people_fixture').run(state,req.params)end,debug.traceback)\n        if ok then reply(id,result) else print(tostring(result));reject(id,'fixture_failed') end\n"+marker);m.FS.writeFile(p,s);
 }});}
let a,b,c;
try{
 a=await make();const created=await a.rpc('create',{seed:41,fixture:'formal'}),g=created.generation;
 report.steps.push({setup:await a.rpc('fixture_named_people',{phase:'setup'},g)});
 const snap=await a.rpc('snapshot_export',{},g);report.checkpoint_bytes=snap.blob.length;
 b=await make();const restored=await b.rpc('snapshot_import',{format:snap.format,blob:snap.blob});
 report.steps.push({restored:await b.rpc('fixture_named_people',{phase:'after_restore'},restored.generation)});
 report.steps.push({transfer:await b.rpc('fixture_named_people',{phase:'transfer'},restored.generation)});
 c=await make();const cg=await c.rpc('create',{seed:41,fixture:'formal'});report.steps.push({boundaries:await c.rpc('fixture_named_people',{phase:'boundary_only'},cg.generation)});
 const levels=[];for(const reference_level of [8,10,12]){const k=await make();try{const g=await k.rpc('create',{seed:41,fixture:'formal'});const r=await k.rpc('fixture_named_people',{phase:'setup',reference_level},g.generation);levels.push({reference_level,actual_level:r.spawn.level});}finally{k.dispose();}}
 if(!(levels[0].actual_level<levels[1].actual_level && levels[1].actual_level<levels[2].actual_level))throw Error('reference level did not produce monotonic native levels: '+JSON.stringify(levels));
 report.steps.push({reference_levels:levels});report.passed=true;report.unverified=['partition cold import'];
}catch(e){report.error=String(e.stack||e);process.exitCode=1;}
finally{a?.dispose();b?.dispose();c?.dispose();report.logs=logs.slice(-40);await mkdir(dirname(out),{recursive:true});await writeFile(out,JSON.stringify(report,null,2));await writeFile(out.replace(/\.json$/,'.log'),logs.join('\n'));console.log(JSON.stringify({passed:report.passed,error:report.error,steps:report.steps.length,logs:logs.slice(-5)}));}
