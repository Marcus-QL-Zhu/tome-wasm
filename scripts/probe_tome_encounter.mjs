// Real compiled rules: read-only inspection, hidden-id rejection and config reset.
import {readFile,writeFile,mkdir} from 'node:fs/promises';
import {resolve,dirname} from 'node:path';
import {pathToFileURL} from 'node:url';
import assert from 'node:assert/strict';
import {EngineBridge} from '../tome_mvp/wasm/engine_bridge.mjs';
const root=resolve(process.argv[2]),output=resolve(process.argv[3]),seed=Number(process.argv[4] || 12);
const bytes=await readFile(resolve(root,'tome.data')),logs=[];
const {default:createTome}=await import(pathToFileURL(resolve(root,'tome.js')));
const identity=JSON.parse(await readFile(resolve(root,'../identity.json'),'utf8'));
const {createKernel}=await import(pathToFileURL(resolve(root,'kernel_runtime.mjs')));
const install=identity.encounter_overlay?(await import(pathToFileURL(resolve(root,'encounter_overlay.mjs')))).installEncounter:null;
const encounterInput=install?JSON.parse(await readFile(resolve(root,'encounter.json'),'utf8')):null;
const kernel=await createKernel(createTome,{wasmBinary:await readFile(resolve(root,'tome.wasm')),getPreloadedPackage:()=>bytes.buffer.slice(bytes.byteOffset,bytes.byteOffset+bytes.byteLength)},
 {prepare:install?m=>install(m,encounterInput):undefined,log:(...s)=>logs.push(s.join(' '))});
const rpc=kernel.rpc;
const b=new EngineBridge(rpc);let s=await b.init(seed);
const initial=structuredClone(s),sheet=await rpc('inspect_actor',{target:s.party[0].id},b.generation);
let bound=null;
const encounter=JSON.parse(await readFile(resolve(root,'../encounter.json'),'utf8'));
if(encounter.map.size){assert.equal(initial.map.length,encounter.map.size);assert.ok(initial.map.every(row=>row.length===encounter.map.size));}
const native=await rpc('dm_inspect',{},b.generation);
if(encounter.party.some(p=>p.campaign_identity)){
 bound=native;
 assert.deepEqual(bound.party.map(p=>[p.world_id,p.origin,p.name]),encounter.party.map(p=>[p.campaign_identity.person_id,p.campaign_identity.origin,p.name]));
}
const catalog=await rpc('content_catalog',{},b.generation);
assert.ok(catalog.talents.length>1000);assert.equal(catalog.all_talents_verified,false);
await mkdir(dirname(output),{recursive:true});await writeFile(output.replace(/\.json$/,'.catalog.json'),JSON.stringify(catalog,null,2));
assert.equal(sheet.name,s.party[0].name);assert.ok(sheet.talents.length);assert.ok(sheet.equipment.length);assert.ok(sheet.stats.str>0);
const after=await rpc('observe',{},b.generation);
for(const key of ['turn','party','enemies','events','talents'])assert.deepEqual(after[key],initial[key],`inspection changed ${key}`);
await assert.rejects(rpc('inspect_actor',{target:999999999},b.generation),/not_visible/);
await assert.rejects(rpc('inspect_actor',{target:s.party[0].id},b.generation+1),/stale_generation/);
const resultReset=await b.command({type:'new_game',seed,revision:s.revision});
if(bound){
 assert.equal(resultReset.status,403,'bound campaign party must reject recreation');
 s=b.state();assert.equal(s.generation,initial.generation);assert.deepEqual(s.party,initial.party);
}else{
 assert.equal(resultReset.status,200,JSON.stringify(resultReset.body));s=resultReset.body;
 assert.equal(s.generation,2);assert.deepEqual(s.party.map(x=>[x.name,x.level,x.max_hp]),initial.party.map(x=>[x.name,x.level,x.max_hp]));
}
assert.equal(logs.filter(x=>x.includes('HEADLESS_TALENT_ERROR_STACK_JSON')).length,0);
await mkdir(dirname(output),{recursive:true});await writeFile(output,JSON.stringify({runtime:'real Wasm',initial,inspection:sheet,native_party:native.party,bound_party:bound?.party || null,read_only:true,hidden_id_rejected:true,stale_generation_rejected:true,reset_preserves_encounter:!bound,bound_reset_rejected:!!bound,logs:logs.slice(-15)},null,2));
kernel.dispose();console.log(JSON.stringify({passed:true,party:s.party.map(x=>x.name),inspection_talents:sheet.talents.length,equipment:sheet.equipment.length}));
