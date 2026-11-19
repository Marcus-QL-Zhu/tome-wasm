// Controlled AI choice, original scheduler frame and native talent/dialog code.
import {readFile,writeFile,mkdir} from 'node:fs/promises';
import {resolve,dirname} from 'node:path';
import {pathToFileURL} from 'node:url';
import assert from 'node:assert/strict';
const root=resolve(process.argv[2]),output=resolve(process.argv[3]),overlay=process.argv.includes('--source');
const {createKernel}=await import(pathToFileURL(resolve(root,'kernel_runtime.mjs')));
const {BattleSession}=await import(pathToFileURL(resolve(root,'battle_session.mjs')));
const {default:createTome}=await import(pathToFileURL(resolve(root,'tome.js')));
const bytes=await readFile(resolve(root,'tome.data')),wasmBinary=await readFile(resolve(root,'tome.wasm'));
async function make(mode){
 const logs=[];const k=await createKernel(async options=>{
  const m=await createTome(options);
  if(overlay){
   for(const name of ['ai_input_task','yieldable_talents','native_inputs','player_aioo','worker','snapshot_experiment','native_control','units','visibility','automation_health','formal_scene'])m.FS.writeFile('/bundle/headless/'+name+'.lua',await readFile(resolve('tome_mvp/headless',name+'.lua'),'utf8'));
   m.FS.writeFile('/bundle/generated/probe.lua',await readFile(resolve('tome_mvp/headless/bootstrap.lua'),'utf8'));
  }
  const path='/bundle/headless/worker.lua',source=m.FS.readFile(path,{encoding:'utf8'});
  const fixture=String.raw`
local base_create=scenario.create
scenario.create=function(...)
 local s=base_create(...);local p=s.player;local floor=s.map(p.x,p.y,s.Map.TERRAIN)
 for x=1,18 do for y=1,18 do s.map(x,y,s.Map.TERRAIN,floor:clone());s.map.lites(x,y,true) end end
 local actors={};for _,a in ipairs(s.allies)do actors[#actors+1]=a end;for _,a in ipairs(s.enemies)do actors[#actors+1]=a end
 for _,a in ipairs(actors)do s.map:remove(a.x,a.y,s.Map.ACTOR);a.x=nil;a.y=nil end
 for i,a in ipairs(actors)do a:move(3+i,10,true) end
 p:learnTalent(p.T_MANA_POOL,true,1,{no_unlearn=true});p.max_mana=1000;p.mana=1000
 p:learnTalent(p.T_ARCANE_COMBAT,true,1,{no_unlearn=true})
 p:learnTalent(p.T_PHASE_DOOR,true,5,{no_unlearn=true})
 p:learnTalent(p.T_SPACETIME_TUNING,true,1,{no_unlearn=true});p.paradox=300;p.min_paradox=0;p.max_paradox=1000
 p:learnTalent(p.T_MATTER_IS_ENERGY,true,1,{no_unlearn=true});p.max_psi=100;p.psi=30;p.psi_regen=0
 if MODE=='async' then p:learnTalent(p.T_DEFILING_TOUCH,true,5,{no_unlearn=true}) end
 if MODE=='decline' or MODE=='fault' or MODE=='down' then
  local t=p:getTalentFromId(p.T_ARCANE_COMBAT);local activate=t.activate
  t.activate=function(self,...)
   local result=activate(self,...)
   if MODE=='fault' then error('controlled_native_choice_fault') end
   if MODE=='down' then s.allies[2]:takeHit(s.allies[2].max_life*100,s.enemies[1]) end
   if MODE=='decline' then return nil end
   return result
  end
 end
 local gem=assert(game.zone:makeEntityByName(game.level,'object','GEM_AMETHYST'));assert(p:addObject(p.INVEN_INVEN,gem))
 return s
end
`.replaceAll('MODE',JSON.stringify(mode));
  const controller=String.raw`
local load_ai=aioo_factory.load_source
aioo_factory.load_source=function(...)
 local c=load_ai(...);local class=c.class
 class.player_ai_start=function(self)self.ai_active=true;game.player:act()end
 class.act=function()
  local p=game.player
  local talent=MODE=='target' and p.T_PHASE_DOOR or MODE=='quantity' and p.T_SPACETIME_TUNING or MODE=='inventory' and p.T_MATTER_IS_ENERGY or MODE=='async' and p.T_DEFILING_TOUCH or p.T_ARCANE_COMBAT
  print('AI_INPUT_BEGIN')
  if MODE=='budget' then while true do p.energy.value=p.energy.value end end
  local result=p:useTalent(talent,nil,nil,nil,nil,false,true)
  print('AI_INPUT_RETURNED:'..tostring(not not result))
  if MODE=='budget_after' then while true do p.energy.value=p.energy.value end end
  if not result then print('AI_INPUT_FALLBACK');p:waitTurn() end
 end
 return c
end
`.replaceAll('MODE',JSON.stringify(mode));
  m.FS.writeFile(path,source.replace("local scenario = require 'scene'","local scenario = require 'scene'\n"+fixture).replace("local aioo_factory = require 'player_aioo'","local aioo_factory = require 'player_aioo'\n"+controller));return m;
 },{wasmBinary,getPreloadedPackage:()=>bytes.buffer.slice(bytes.byteOffset,bytes.byteOffset+bytes.byteLength)},{log:(...v)=>{logs.push(v.join(' '));if(logs.length>120)logs.shift();}});
 return {k,logs};
}
const select=process.argv.find(v=>v.startsWith('--modes='));
const modes=select?select.slice(8).split(','):process.argv.includes('--choice-only')?['choice']:['choice','cancel','target','quantity','inventory','async','decline','down','fault'];
const report={runtime:'real Wasm',fixture_override:true,source_overlay:overlay,cases:[]};
for(const mode of modes){let a,b;
 try{
  a=await make(mode);const s=new BattleSession(a.k.rpc,'controlled-ai-input:'+mode,23);await s.init();const initial=structuredClone(s.bridge.state());
  let result=await s.execute('command',{type:'ai_start',mode:'sweep',budget:10,revision:s.bridge.revision});assert.equal(result.status,200);
  result=await s.execute('command',{type:'ai_step',revision:s.bridge.revision,control_epoch:s.bridge.epoch});
  if(mode==='budget'){assert.equal(result.status,500);assert.equal(s.bridge.locked,true);assert.ok(a.logs.some(v=>v.includes('instruction budget exceeded')));report.cases.push({mode,instruction_budget_preserved:true,unknown_locked:true});continue;}
  assert.equal(result.status,200,JSON.stringify(result.body).slice(0,1000));assert.equal(result.body.advance_status,'await_input');assert.ok(result.body.input_request);assert.equal(result.body.ai_status,'stopped');assert.equal(s.bridge.authorized,false);
  assert.ok(!a.logs.some(v=>v.startsWith('AI_INPUT_RETURNED:')||v==='AI_INPUT_FALLBACK'));
  assert.equal(result.body.turn,initial.turn);assert.equal(result.body.party[0].x,initial.party[0].x);
  const archive=await s.suspend();b=await make(mode);const r=await BattleSession.restore(b.k.rpc,archive.build,archive);assert.deepEqual(r.bridge.state(),s.bridge.state());s.suspended=false;
  const pending=r.bridge.state().input_request.id;
  const stale=await s.execute('command',{type:'input_response',input_id:pending+99,cancel:true,revision:s.bridge.revision});assert.equal(stale.status,400);
  assert.equal((await r.execute('command',{type:'input_response',input_id:pending+99,cancel:true,revision:r.bridge.revision})).status,400);
  const pause={type:'ai_stop',reason:'user',revision:s.bridge.revision};assert.deepEqual(await s.execute('command',pause),await r.execute('command',pause));assert.equal(s.bridge.state().input_request.id,pending);assert.equal(s.bridge.state().turn,initial.turn);
  for(let phase=0;phase<4 && s.bridge.state().input_request;phase++){
   const input=s.bridge.state().input_request;let answer;
   if(mode==='cancel')answer={cancel:true};
   else if(input.kind==='choice'){const option=mode==='async'?input.options[0]:input.options.find(o=>mode==='inventory'?o.label.toLowerCase().includes('amethyst'):o.label.includes('Random spells'));assert.ok(option,JSON.stringify(input));answer={choice:option.id};}
   else if(input.kind==='quantity')answer={value:250};
   else answer=phase===0?{x:initial.party[0].x,y:initial.party[0].y}:{x:4,y:6};
   const cmd={type:'input_response',input_id:input.id,...answer,revision:s.bridge.revision};result=await s.execute('command',cmd);assert.deepEqual(await r.execute('command',cmd),result);
   if(mode==='fault'||mode==='budget_after'){assert.equal(result.status,500);assert.equal(s.bridge.locked,true);break;}
   assert.equal(result.status,200,JSON.stringify(result.body).slice(0,900));
   if(mode==='target' && s.bridge.state().input_request){const midway=await s.suspend(),c=await make(mode);try{const checked=await BattleSession.restore(c.k.rpc,midway.build,midway);assert.deepEqual(checked.bridge.state(),s.bridge.state());}finally{c.k.dispose();s.suspended=false;}}
  }
  if(mode==='fault'||mode==='budget_after'){assert.ok(a.logs.some(v=>v.includes(mode==='fault'?'controlled_native_choice_fault':'instruction budget exceeded')));assert.ok(!a.logs.includes('AI_INPUT_FALLBACK'));report.cases.push({mode,unknown_locked:true,no_fallback:true});continue;}
  assert.equal(s.bridge.state().input_request,null);assert.equal(s.bridge.locked,false);assert.equal(s.bridge.state().ai_status,'stopped');assert.equal(s.bridge.authorized,false);assert.ok(!a.logs.includes('AI_INPUT_FALLBACK'));
  if(['cancel','async','decline','down'].includes(mode)){assert.ok(!a.logs.some(v=>v.startsWith('AI_INPUT_RETURNED:')));if(mode==='cancel')assert.equal(s.bridge.state().turn,initial.turn);}
  else assert.equal(a.logs.filter(v=>v==='AI_INPUT_RETURNED:true').length,1);
  if(mode==='down'){assert.equal(s.bridge.state().status,'awaiting_down_confirmation');assert.ok(s.bridge.state().down_events.length);}
  if(mode==='async')assert.equal(s.bridge.state().last_action.outcome,'native_input_resolved');
  const saved=await s.suspend();const restored=await make(mode);try{const check=await BattleSession.restore(restored.k.rpc,saved.build,saved);assert.deepEqual(check.bridge.state(),s.bridge.state());}finally{restored.k.dispose();}
  report.cases.push({mode,paused_before_fallback:true,pending_replay:true,stale_rejected:true,completed_once:true,no_fallback:true,no_auto_restart:true,final:s.bridge.state().last_action,turn:s.bridge.state().turn});
 }catch(e){report.error={mode,message:String(e.stack||e)};report.logs=a?.logs.slice(-30);process.exitCode=1;break;}
 finally{a?.k.dispose();b?.k.dispose();}
}
report.passed=report.cases.length===modes.length;await mkdir(dirname(output),{recursive:true});await writeFile(output,JSON.stringify(report,null,2));console.log(JSON.stringify({...report,logs:undefined}));
