// Isolated Wasm proof; overlays working-tree Lua into the frozen kernel in memory.
import {readFile, writeFile, mkdir} from 'node:fs/promises';
import {resolve} from 'node:path';
import {pathToFileURL} from 'node:url';
const root=resolve(process.argv[2] || 'artifacts/tome-zone-calibration-20261114/kernel-r2/public');
const out=resolve(process.argv[3] || 'artifacts/native-region-20261115/local-area-probe.log');
const {createKernel}=await import(pathToFileURL(resolve(root,'kernel_runtime.mjs')));
const {EngineBridge}=await import(pathToFileURL(resolve(root,'engine_bridge.mjs')));
const {installNativeZoneFixes}=await import(pathToFileURL(resolve(root,'native_zone_overlay.mjs')));
const {installEncounter}=await import(pathToFileURL(resolve(root,'encounter_overlay.mjs')));
const {default:createTome}=await import(pathToFileURL(resolve(root,'tome.js')));
const data=await readFile(resolve(root,'tome.data')), wasmBinary=await readFile(resolve(root,'tome.wasm'));
const encounter=JSON.parse(await readFile('artifacts/tome-zone-calibration-20261114/encounter-r2/public/encounter.json','utf8'));
const fixture=await readFile(process.argv[4] || 'tests/tome_local_area_probe.lua','utf8');
const logs=[];let kernel;
try {
 kernel=await createKernel(createTome,{wasmBinary,getPreloadedPackage:()=>data.buffer.slice(data.byteOffset,data.byteOffset+data.byteLength)},
  {log:(...x)=>logs.push(x.join(' ')),prepare:async m=>{
   installNativeZoneFixes(m);installEncounter(m,encounter);
   for(const name of ['local_area','native_zone','formal_map','formal_scene','scene_placement','dm_progression'])m.FS.writeFile('/bundle/headless/'+name+'.lua',await readFile('tome_mvp/headless/'+name+'.lua','utf8'));
   const path='/bundle/headless/worker.lua';let text=m.FS.readFile(path,{encoding:'utf8'});
   if(!text.includes('return create_scene(...)'))throw Error('missing fixture insertion point');
   text=text.replace('return create_scene(...)',`local s=create_scene(...)\n${fixture}\nreturn s`);m.FS.writeFile(path,text);
  }});
 await new EngineBridge(kernel.rpc).init(41);
 if(!logs.some(x=>x.includes('LOCAL_AREA_PROBE_OK')))throw Error('probe did not complete');
} catch(e) {logs.push(String(e.stack||e));process.exitCode=1;} finally {kernel?.dispose();await mkdir(resolve(out,'..'),{recursive:true});await writeFile(out,logs.join('\n'));console.log(logs.slice(-35).join('\n'));}
