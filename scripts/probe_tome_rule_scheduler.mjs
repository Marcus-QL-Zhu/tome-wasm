// Controlled scheduler fixture: it changes the actor list and AI, never the
// original scheduler, callback, rescue wrapper or rule-event implementation.
import {readFile,writeFile,mkdir} from 'node:fs/promises';
import {resolve,dirname} from 'node:path';
import {pathToFileURL} from 'node:url';
import assert from 'node:assert/strict';
const root=resolve(process.argv[2]),output=resolve(process.argv[3]);
const {createKernel}=await import(pathToFileURL(resolve(root,'kernel_runtime.mjs')));
const {BattleSession}=await import(pathToFileURL(resolve(root,'battle_session.mjs')));
const {default:createTome}=await import(pathToFileURL(resolve(root,'tome.js')));
const bytes=await readFile(resolve(root,'tome.data')),wasmBinary=await readFile(resolve(root,'tome.wasm'));
async function make(remove){
 const logs=[];
 const k=await createKernel(async options=>{
  const m=await createTome(options),path='/bundle/headless/worker.lua',source=m.FS.readFile(path,{encoding:'utf8'});
  const fixture=String.raw`
local scheduler_probe_start,scheduler_probe_resume
local base_create=scenario.create
scenario.create=function(...)
 local s=base_create(...);local a,b=s.enemies[1],s.enemies[2];local counts={a=0,b=0,g=0,base=0}
 local level=game.level;local arr,iteration,entities=level.e_array,level.last_iteration,game.entities
 local energy_tick=require('engine.GameEnergyBased').tick
 local native_base=a.actBase
 a.actBase=function(self,...)counts.base=counts.base+1;return native_base(self,...)end
 a.doAI=function(self)
  counts.a=counts.a+1;self:useEnergy()
  if counts.a==1 then
   local h=s.map:particleEmitter(a.x,a.y,1,'scheduler_probe',{})
   h.on_remove=function()
    s.allies[2]:takeHit(s.allies[2].max_life*100,a)
    if REMOVE then game.level:removeEntity(a) end
   end
  end
 end
 b.doAI=function(self)counts.b=counts.b+1;self:useEnergy();game.paused=true end
 a.energy.value=2500;a.energy.mod=0;a.energyBase=1000
 b.energy.value=1000;b.energy.mod=0;b.energyBase=0
 local global={uid=987654,energy={value=1000,mod=0},act=function(self)counts.g=counts.g+1;self.energy.value=0 end}
 scheduler_probe_start=function()
  level.e_array={a,b};level.last_iteration=nil;game.entities={[global.uid]=global};game.paused=false
  energy_tick(game)
  assert(counts.a==1 and counts.b==0 and counts.g==0,'actor acted after rule interruption')
  assert(counts.base==1,'actBase repeated before confirmation')
  assert(require('rule_events').interrupted(),'rule interrupt not latched')
  print('SCHEDULER_PROBE:before:1,0,0,1')
 end
 scheduler_probe_resume=function()
  assert(not require('rule_events').interrupted(),'confirmation did not clear rule interruption')
  game.paused=false;energy_tick(game)
  assert(counts.a==1 and counts.b==1 and counts.g==1,'native cursor did not continue at next actor')
  assert(counts.base==1,'completed actor actBase repeated after confirmation')
  level.e_array=arr;level.last_iteration=iteration;game.entities=entities
  print('SCHEDULER_PROBE:after:1,1,1,1')
 end
 return s
end
`.replaceAll('REMOVE',remove?'true':'false');
  m.FS.writeFile(path,source.replace("local scenario = require 'scene'","local scenario = require 'scene'\n"+fixture)
   .replaceAll('bind_down_listener(true); refresh_visibility()','bind_down_listener(true);if scheduler_probe_start then scheduler_probe_start() end;refresh_visibility()')
   .replace("require('rule_events').resume_after_confirmation()","require('rule_events').resume_after_confirmation();if scheduler_probe_resume then scheduler_probe_resume() end"));return m;
 },{wasmBinary,getPreloadedPackage:()=>bytes.buffer.slice(bytes.byteOffset,bytes.byteOffset+bytes.byteLength)},{log:(...v)=>{logs.push(v.join(' '));if(logs.length>60)logs.shift();}});
 return {k,logs};
}
const report={runtime:'real Wasm',fixture_override:true,cases:[]};
for(const remove of [false,true]){
 let first,second;
 try{
  first=await make(remove);const s=new BattleSession(first.k.rpc,'scheduler:'+remove,23);await s.init();
  assert.equal(s.bridge.state().status,'awaiting_down_confirmation');assert.ok(first.logs.includes('SCHEDULER_PROBE:before:1,0,0,1'));
  const event=s.bridge.state().down_events[0],r=await s.execute('command',{type:'confirm_down',event_id:event.id,generation:1,revision:s.bridge.revision});
  assert.equal(r.status,200);assert.ok(first.logs.includes('SCHEDULER_PROBE:after:1,1,1,1'));
  const archive=await s.suspend();second=await make(remove);const restored=await BattleSession.restore(second.k.rpc,archive.build,archive);assert.deepEqual(restored.bridge.state(),s.bridge.state());
  report.cases.push({remove_current_actor:remove,high_speed_stopped_after_one:true,next_actor_waited_for_confirmation:true,global_actor_waited:true,actBase_not_repeated:true,native_cursor_preserved:true,replay_identical:true});
 }catch(e){report.error=String(e.stack||e);report.logs=first?.logs;process.exitCode=1;break;}
 finally{first?.k.dispose();second?.k.dispose();}
}
report.passed=report.cases.length===2;await mkdir(dirname(output),{recursive:true});await writeFile(output,JSON.stringify(report,null,2));console.log(JSON.stringify({...report,error:report.error?.slice(-2000),logs:undefined}));
