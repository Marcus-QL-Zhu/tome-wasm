// A controlled scheduler fixture tests quarantine, not AI tactical selection.
import {readFile,writeFile,mkdir} from 'node:fs/promises';
import {resolve,dirname} from 'node:path';
import {pathToFileURL} from 'node:url';
import assert from 'node:assert/strict';
const root=resolve(process.argv[2]),output=resolve(process.argv[3]);
const {createKernel}=await import(pathToFileURL(resolve(root,'kernel_runtime.mjs')));
const {EngineBridge}=await import(pathToFileURL(resolve(root,'engine_bridge.mjs')));
const {default:createTome}=await import(pathToFileURL(resolve(root,'tome.js')));
const bytes=await readFile(resolve(root,'tome.data')),logs=[],calls=[],report={runtime:'real Wasm',fixture_override:true,scope:'native input barrier after controlled AI step'};let k;
try{
 k=await createKernel(async options=>{
  const m=await createTome(options),path='/bundle/headless/worker.lua',source=m.FS.readFile(path,{encoding:'utf8'});
  const fixture=String.raw`
local factory=require 'player_aioo';local load=factory.load_source
factory.load_source=function(...)
 local controller=load(...)
 controller.lifecycle_step=function()
  game.player:learnTalent(game.player.T_ARCANE_COMBAT,true,1,{no_unlearn=true})
  -- An untracked nested scheduler must not make an orphaned menu answerable.
  local orphan=coroutine.create(function()game.player:useTalent(game.player.T_ARCANE_COMBAT,nil,nil,nil,nil,false,true)end)
  local ok,err=coroutine.resume(orphan);assert(ok,err)
  assert(require('native_inputs').has_pending(),'fixture did not create a real native menu')
  return 'acted'
 end
 return controller
end
`;
  m.FS.writeFile(path,source.replace("local aioo_factory = require 'player_aioo'","local aioo_factory = require 'player_aioo'\n"+fixture));return m;
 },{wasmBinary:await readFile(resolve(root,'tome.wasm')),getPreloadedPackage:()=>bytes.buffer.slice(bytes.byteOffset,bytes.byteOffset+bytes.byteLength)}, {request:(...x)=>calls.push(x[0]),log:(...x)=>{logs.push(x.join(' '));if(logs.length>15)logs.shift();}});
 const b=new EngineBridge(k.rpc);await b.init(23);let r=await b.command({type:'ai_start',mode:'sweep',budget:10,revision:0});assert.equal(r.status,200);const prior=structuredClone(b.snapshot);
 r=await b.command({type:'ai_step',revision:r.body.revision,control_epoch:r.body.control_epoch});assert.equal(r.status,500);assert.equal(b.locked,true);assert.deepEqual(b.snapshot,prior);
 const count=calls.length;assert.equal((await b.command({type:'wait',revision:b.revision})).status,500);assert.equal(calls.length,count);
 assert.ok(logs.some(x=>x.includes('native_ai_interactive_input_unverified')));report.last_confirmed_preserved=true;report.no_retry_or_new_action=true;report.passed=true;
}catch(e){report.error=String(e.stack || e);process.exitCode=1;}
finally{k?.dispose();report.logs=logs;await mkdir(dirname(output),{recursive:true});await writeFile(output,JSON.stringify(report,null,2));console.log(JSON.stringify({...report,logs:undefined}));}
