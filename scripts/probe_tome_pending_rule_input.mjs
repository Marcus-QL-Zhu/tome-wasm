import {readFile,writeFile,mkdir} from 'node:fs/promises';
import {resolve,dirname} from 'node:path';
import {pathToFileURL} from 'node:url';
import assert from 'node:assert/strict';
const root=resolve(process.argv[2]),output=resolve(process.argv[3]);
const {createKernel}=await import(pathToFileURL(resolve(root,'kernel_runtime.mjs')));
const {BattleSession}=await import(pathToFileURL(resolve(root,'battle_session.mjs')));
const {default:createTome}=await import(pathToFileURL(resolve(root,'tome.js')));
const bytes=await readFile(resolve(root,'tome.data')),wasmBinary=await readFile(resolve(root,'tome.wasm'));
async function make(){
 const logs=[];const k=await createKernel(async options=>{
  const m=await createTome(options),path='/bundle/headless/worker.lua',source=m.FS.readFile(path,{encoding:'utf8'});
  const fixture=String.raw`
local base_create=scenario.create
scenario.create=function(...)
 local s=base_create(...);local p=s.player
 p:learnTalent(p.T_MANA_POOL,true,1,{no_unlearn=true});p.max_mana=1000;p.mana=1000
 p:learnTalent(p.T_FLAME,true,1,{no_unlearn=true})
 local t=p:getTalentFromId(p.T_FLAME);local action=t.action
 t.action=function(self,...)
  s.map:particleEmitter(self.x,self.y,1,'pending_input_probe',{}).on_remove=function()print('PENDING_INPUT_RULE_FIRED')end
  return action(self,...)
 end
 return s
end
`;
  m.FS.writeFile(path,source.replace("local scenario = require 'scene'","local scenario = require 'scene'\n"+fixture));return m;
 },{wasmBinary,getPreloadedPackage:()=>bytes.buffer.slice(bytes.byteOffset,bytes.byteOffset+bytes.byteLength)},{log:(...v)=>{logs.push(v.join(' '));if(logs.length>70)logs.shift();}});
 return {k,logs};
}
const report={runtime:'real Wasm',fixture_override:true};let first,second;
try{
 first=await make();const s=new BattleSession(first.k.rpc,'pending-rule-input',23);await s.init();
 const result=await s.execute('command',{type:'talent',talent:'T_FLAME',revision:s.bridge.revision});assert.equal(result.status,200);assert.equal(result.body.input_request.kind,'target');assert.equal(result.body.rule_events[0].phase,'pending');
 await assert.rejects(first.k.rpc('act',{type:'wait'},1),e=>e.outcome==='rejected'&&e.message==='native_input_pending');
 await assert.rejects(first.k.rpc('save',{},1),e=>e.outcome==='rejected'&&e.message==='rule_events_pending');
 const archive=await s.suspend();assert.ok(!first.logs.includes('PENDING_INPUT_RULE_FIRED'));
 second=await make();const r=await BattleSession.restore(second.k.rpc,archive.build,archive);assert.ok(!second.logs.includes('PENDING_INPUT_RULE_FIRED'));s.suspended=false;
 const cancel={type:'input_response',input_id:s.bridge.state().input_request.id,cancel:true,revision:s.bridge.revision};assert.deepEqual(await s.execute('command',cancel),await r.execute('command',cancel));
 assert.equal(first.logs.filter(x=>x==='PENDING_INPUT_RULE_FIRED').length,1);assert.equal(second.logs.filter(x=>x==='PENDING_INPUT_RULE_FIRED').length,1);assert.equal(s.bridge.state().input_request,null);assert.equal(s.bridge.state().rule_events[0].phase,'done');
 report.passed=true;report.pending_choice_and_rule_replayed=true;report.raw_action_bypass_rejected=true;report.raw_graph_save_rejected=true;report.save_did_not_fire_callback=true;report.cancel_return_settled_once=true;
}catch(e){report.error=String(e.stack||e);report.logs=first?.logs;process.exitCode=1;}
finally{first?.k.dispose();second?.k.dispose();await mkdir(dirname(output),{recursive:true});await writeFile(output,JSON.stringify(report,null,2));console.log(JSON.stringify({...report,error:report.error?.slice(-1600),logs:undefined}));}
