// Native creation/reset checks over the same frozen package used by the browser.
import {readFile,writeFile,mkdir} from 'node:fs/promises';
import {resolve,dirname} from 'node:path';
import {pathToFileURL} from 'node:url';
import assert from 'node:assert/strict';
const root=resolve(process.argv[2]),output=resolve(process.argv[3]);
const {default:createTome}=await import(pathToFileURL(resolve(root,'tome.js')));
const {createKernel}=await import(pathToFileURL(resolve(root,'kernel_runtime.mjs')));
const {installEncounter}=await import(pathToFileURL(resolve(root,'encounter_overlay.mjs')));
const data=await readFile(resolve(root,'tome.data'));
const party=['184917','159442','425367'].map(template=>({template}));
const enemies=Array.from({length:5},(_,i)=>({prototype:'orc warrior',kind:'rare',class:['Bulwark','Berserker','Archmage','Bulwark','Berserker'][i],level:15,hp_multiplier:1}));
const specs=[];
for(const kind of ['dungeon','forest','cave','town','tavern'])for(const size of [10,37,64])for(const seed of [201,202])specs.push({kind,size,seed});
specs.push({...specs[0]});
let preview,logs=[],initial=specs[0];
const manifest=spec=>({format:'tome-encounter-v1',seed:spec.seed,party,enemies,map:{kind:spec.kind,size:spec.size}});
const kernel=await createKernel(createTome,{wasmBinary:await readFile(resolve(root,'tome.wasm')),getPreloadedPackage:()=>data.buffer.slice(data.byteOffset,data.byteOffset+data.byteLength)},{
 prepare:m=>{
  installEncounter(m,manifest(initial));
  const path='/bundle/headless/formal_map.lua',s=m.FS.readFile(path,{encoding:'utf8'});
  assert.equal(s.split('\nreturn M').length,2);
  const wrap=`\nlocal original_create=M.create\nM.create=function(...)\n local g=original_create(...)\n local rows=require('json_validate').array()\n for y=0,g.map.h-1 do local row=''\n  for x=0,g.map.w-1 do local t=g.map(x,y,require('engine.Map').TERRAIN)\n   local ch=t.door_opened and '+' or (t.block_move and '#' or '.')\n   row=row..ch\n  end\n  rows[#rows+1]=row\n end\n print('GENERATED_MAP_JSON '..require('json_validate').encode(require('json_validate').object({rows=rows,reachable=g.reachable,attempts=g.attempts})))\n return g\nend\nreturn M`;
  m.FS.writeFile(path,s.replace('\nreturn M',wrap));
 },log:(...parts)=>{const line=parts.join(' ');if(line.startsWith('GENERATED_MAP_JSON '))preview=JSON.parse(line.slice(19));logs.push(line);if(logs.length>30)logs.shift();}
});
const results=[];
let generation;
try{
 for(const [index,spec]of specs.entries()){
  installEncounter(kernel.mod,manifest(spec));preview=null;
  const receipt=await kernel.rpc(index===0?'create':'reset',{seed:spec.seed,fixture:'formal'},generation);
  generation=receipt.generation;
  assert.equal(receipt.accepted,true);
  const view=await kernel.rpc('observe',{},receipt.generation);
  assert.equal(view.map.length,spec.size);assert.ok(view.map.every(row=>row.length===spec.size));
  assert.equal(view.party.length,3);assert.ok(preview?.reachable>20);
  results.push({...spec,...preview,reset_generation:receipt.generation,party:view.party.map(a=>({name:a.name,level:a.level,x:a.x,y:a.y}))});
 }
 assert.deepEqual(results.at(-1).rows,results[0].rows);
 await mkdir(dirname(output),{recursive:true});await writeFile(output,JSON.stringify({passed:true,checks:results.length,repeat_seed_equal:true,results},null,2));
 console.log(JSON.stringify({passed:true,checks:results.length,kinds:5,sizes:[10,37,64],repeat_seed_equal:true}));
}catch(e){await mkdir(dirname(output),{recursive:true});await writeFile(output,JSON.stringify({passed:false,error:String(e.stack||e),completed:results,logs},null,2));throw e;}
finally{kernel.dispose();}
