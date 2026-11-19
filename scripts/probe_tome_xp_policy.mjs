// Test-only in-memory instrumentation of the real native actor XP entry point.
import {readFile,writeFile} from 'node:fs/promises';
import {resolve} from 'node:path';
import {pathToFileURL} from 'node:url';
const root=resolve(process.argv[2]),output=resolve(process.argv[3]);
const {createKernel}=await import(pathToFileURL(resolve(root,'kernel_runtime.mjs')));
const {BattleSession}=await import(pathToFileURL(resolve(root,'battle_session.mjs')));
const {default:createTome}=await import(pathToFileURL(resolve(root,'tome.js')));
const {installEncounter}=await import(pathToFileURL(resolve(root,'encounter_overlay.mjs')));
const bytes=await readFile(resolve(root,'tome.data'));
const identity=JSON.parse(await readFile(resolve(root,'../identity.json'),'utf8'));
const encounter=JSON.parse(await readFile(resolve(root,'encounter.json'),'utf8'));
const probe=`
 if a._dm_world_id then
  local original=a.exp;local turn=game.turn
  a.exp=2
  a:gainExp(1)
  assert(a.exp==2,'unmanaged positive XP escaped interception')
  a:gainExp(-1)
  assert(a.exp==1,'native negative XP was blocked')
  a.exp=original
  assert(game.turn==turn,'policy probe advanced combat')
 end
`;
const logs=[];
const kernel=await createKernel(createTome,{wasmBinary:await readFile(resolve(root,'tome.wasm')),getPreloadedPackage:()=>bytes.buffer.slice(bytes.byteOffset,bytes.byteOffset+bytes.byteLength)},{log:(...x)=>{logs.push(x.join(' '));if(logs.length>15)logs.shift();},prepare:mod=>{
 installEncounter(mod,encounter);
 const path='/bundle/headless/dm_progression.lua',source=mod.FS.readFile(path,{encoding:'utf8'});
 if(source.split('function M.snapshot(a)').length!==2)throw Error('unknown snapshot boundary');
 mod.FS.writeFile(path,source.replace('function M.snapshot(a)','function M.snapshot(a)'+probe).replace('return json.object({exp=','return json.object({policy_probe=true,exp='));
}});
try{
 const session=new BattleSession(kernel.rpc,identity.build_id,encounter.seed);await session.init();
 const native=await kernel.rpc('dm_inspect',{},session.bridge.generation);
 if(!native.party.every(x=>x.progression.policy_probe===true))throw Error('probe not run for every bound actor');
 const result={status:'passed',actors:native.party.map(x=>x.world_id),positive_suppressed:true,negative_preserved:true,test_only_in_memory_patch:true};
 await writeFile(output,JSON.stringify(result,null,2));process.stdout.write(JSON.stringify(result));
}catch(e){await writeFile(output,JSON.stringify({error:e.message,logs},null,2));throw e;}finally{kernel.dispose();}
