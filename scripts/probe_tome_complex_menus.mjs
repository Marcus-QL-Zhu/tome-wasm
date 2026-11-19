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
  const m=await createTome({...options,printErr:(...v)=>{logs.push('STDERR '+v.join(' '));if(logs.length>120)logs.shift();}});
  if(overlay){
   for(const name of ['native_inputs','native_dialogs'])m.FS.writeFile('/bundle/headless/'+name+'.lua',await readFile(resolve('tome_mvp/headless',name+'.lua'),'utf8'));
   m.FS.writeFile('/bundle/generated/rules.lua',await readFile(resolve('artifacts/tome-complex-menus-20261112/generated/rules.lua'),'utf8'));
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
 if MODE=='golem_jump' then p.alchemy_golem.sentient_telos=1 end
 p:learnTalent(p.T_MANA_POOL,true,1,{no_unlearn=true});p.max_mana=1000;p.mana=1000
 p:learnTalent(p.T_STAMINA_POOL,true,1,{no_unlearn=true});p.max_stamina=1000;p.stamina=1000
 p:learnTalent(p.T_SPACETIME_TUNING,true,1,{no_unlearn=true});p.paradox=300
 if MODE=='tools' or MODE=='row' then p:learnTalent(p.T_ROGUE_S_TOOLS,true,1,{no_unlearn=true}) end
 if MODE=='priming' then p:learnTalent(p.T_TRAP_PRIMING,true,1,{no_unlearn=true}) end
 if MODE=='empower' then p:learnTalent(p.T_REPULSION_BLAST,true,1,{no_unlearn=true});p:learnTalent(p.T_EMPOWER,true,1,{no_unlearn=true}) end

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
  if (MODE=='golem_equipment' or MODE=='golem_equipment_cancel') then
   local ItemDialog=require 'mod.dialogs.UseItemDialog';local useitem=ItemDialog.use
   ItemDialog.use=function(self,row)
    local obj=self.object;local inven=self.inven;local index=self.item
    local result=useitem(self,row)
    if row.action=='takeoff' then
     assert(inven[index]~=obj,'native takeoff failed');local found=false
     for _,v in ipairs(p:getInven('INVEN')) do if v==obj then found=true end end
     assert(found,'native destination missing item');print('GOLEM_TAKEOFF_OK')
    elseif row.action=='wear' then
     local found=false;for _,v in ipairs(self.actor:getInven('MAINHAND')) do if v==obj then found=true end end
     assert(found,'native wear failed');print('GOLEM_WEAR_OK')
    end
    return result
   end
  end
  if (MODE=='golem' or MODE=='golem_no' or (MODE=='golem_equipment' or MODE=='golem_equipment_cancel') or MODE=='golem_popup_cancel' or MODE=='golem_skill') then
   local L=require 'mod.dialogs.LevelupDialog'; local use=L.onUseTalent
   L.onUseTalent=function(self,item,inc)
    local before=self.actor:getStat(self.actor.STAT_STR,nil,true,true);local points=self.actor.unused_stats
    local rank=item.talent and self.actor:getTalentLevelRaw(item.talent);local classpoints=self.actor.unused_talents
    local result=use(self,item,inc)
    if MODE=='golem_skill' and item.talent and inc then assert(self.actor:getTalentLevelRaw(item.talent)==rank+1 and self.actor.unused_talents==classpoints-1,'native talent allocation');print('GOLEM_TALENT_ALLOCATED') end
    if item.stat==self.actor.STAT_STR and inc then assert(self.actor:getStat(self.actor.STAT_STR,nil,true,true)==before+1 and self.actor.unused_stats==points-1,'native stat allocation');print('GOLEM_STAT_ALLOCATED') end
    return result
   end
   local cancel=L.cancel
   L.cancel=function(self,...) local before=self.actor_dup:getStat(self.actor_dup.STAT_STR,nil,true,true);local points=self.actor_dup.unused_stats;local result=cancel(self,...);assert(self.actor:getStat(self.actor.STAT_STR,nil,true,true)==before and self.actor.unused_stats==points,'native rollback');print('GOLEM_ROLLBACK_OK');return result end
  end
  if MODE=='row' then
   local ChatDialog=require 'engine.dialogs.Chat';local original=ChatDialog.generateList
   ChatDialog.generateList=function(self,...) local ret=original(self,...); for _,row in ipairs(self.list) do if tostring(row.name):find('Hidden Blades',1,true) then row.fct=function(item,button,event) assert(item==row and button=='left' and event=='key','VariableList row callback signature');print('ROW_CALLBACK_OK');self:use(item) end end end;return ret end
  end
  if MODE=='mastery' and not p:knowTalent(p.T_TRAP_MASTERY) then p:learnTalent(p.T_TRAP_MASTERY,true,1,{no_unlearn=true}) end
  local talent=(MODE=='tools' or MODE=='row') and p.T_ROGUE_S_TOOLS or MODE=='mastery' and p.T_TRAP_MASTERY or MODE=='priming' and p.T_TRAP_PRIMING or (MODE=='golem' or MODE=='golem_no' or (MODE=='golem_equipment' or MODE=='golem_equipment_cancel') or MODE=='golem_popup_cancel' or MODE=='golem_skill' or MODE=='golem_jump') and p.T_INTERACT_GOLEM or p.T_EMPOWER
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
const modes=select?select.slice(8).split(','):process.argv.includes('--choice-only')?['choice']:['tools','mastery','priming','empower'];
const report={runtime:'real Wasm',fixture_override:true,source_overlay:overlay,cases:[]};
for(const mode of modes){let a,b;
 try{
  a=await make(mode);const s=new BattleSession(a.k.rpc,'controlled-ai-input:'+mode,23);await s.init();const initial=structuredClone(s.bridge.state());
  assert.equal(initial.input_request,null,'unexpected birth input');
  if(mode==='mastery'){const wait=await s.execute('command',{type:'wait',revision:s.bridge.revision});assert.equal(wait.status,200,JSON.stringify(wait.body));}
  const beforeAi=structuredClone(s.bridge.state());
  let result=await s.execute('command',{type:'ai_start',mode:'sweep',budget:10,revision:s.bridge.revision});assert.equal(result.status,200,JSON.stringify(result.body));
  result=await s.execute('command',{type:'ai_step',revision:s.bridge.revision,control_epoch:s.bridge.epoch});
  if(mode==='budget'){assert.equal(result.status,500);assert.equal(s.bridge.locked,true);assert.ok(a.logs.some(v=>v.includes('instruction budget exceeded')));report.cases.push({mode,instruction_budget_preserved:true,unknown_locked:true});continue;}
  assert.equal(result.status,200,JSON.stringify(result.body).slice(0,1000));assert.equal(result.body.advance_status,'await_input');assert.ok(result.body.input_request);assert.equal(result.body.ai_status,'stopped');assert.equal(s.bridge.authorized,false);
  assert.ok(!a.logs.some(v=>v.startsWith('AI_INPUT_RETURNED:')||v==='AI_INPUT_FALLBACK'));
  assert.equal(result.body.turn,beforeAi.turn);assert.equal(result.body.party[0].x,initial.party[0].x);
  const archive=await s.suspend();b=await make(mode);const r=await BattleSession.restore(b.k.rpc,archive.build,archive);assert.deepEqual(r.bridge.state(),s.bridge.state());s.suspended=false;
  const pending=r.bridge.state().input_request.id;
  const stale=await s.execute('command',{type:'input_response',input_id:pending+99,cancel:true,revision:s.bridge.revision});assert.equal(stale.status,400);
  assert.equal((await r.execute('command',{type:'input_response',input_id:pending+99,cancel:true,revision:r.bridge.revision})).status,400);
  const pause={type:'ai_stop',reason:'user',revision:s.bridge.revision};assert.deepEqual(await s.execute('command',pause),await r.execute('command',pause));assert.equal(s.bridge.state().input_request.id,pending);assert.equal(s.bridge.state().turn,beforeAi.turn);
  const seen=[];
  for(let phase=0;phase<8 && s.bridge.state().input_request;phase++){
   const input=s.bridge.state().input_request;seen.push(input);
   const option=input.options.find(o=>mode==='mastery'?o.label.includes('Bear Trap'):mode==='empower'?o.label.includes('Repulsion Blast'):(mode==='tools'||mode==='row')?o.label.includes('Equip Hidden Blades'):mode==='golem_jump'?(phase===0?o.label.includes('How is it that you speak'):o.label.includes("Nothing, let's go")):mode.startsWith('golem_equipment')?(phase===0?o.label.toLowerCase().includes('equipment'):phase===1?o.label.startsWith('MAINHAND:'):phase===2?o.label==='Take off':mode==='golem_equipment_cancel'?o.label==='Close':phase===3?o.label.includes('steel battleaxe'):phase===4?o.label==='Wield/Wear':o.label==='Close'):mode.startsWith('golem')?(phase===0?o.label.toLowerCase().includes(mode==='golem_equipment'?'equipment':'talents'):phase===1?o.label===(mode==='golem_skill'?'+ Knockback':'+ Strength'):phase===2?o.label==='Finish / close':mode==='golem_popup_cancel'&&phase===3?o.label==='Cancel':mode==='golem_popup_cancel'&&phase===4?o.label==='Finish / close':o.label===(mode==='golem_no'?'No':'Yes')):o.label.includes('Bear Trap'));
   const cancel=process.argv.includes('--cancel') || (mode==='golem_equipment_cancel' && phase===2);
   if(!cancel)assert.ok(option,JSON.stringify(input));
   const cmd={type:'input_response',input_id:input.id,...(cancel?{cancel:true}:{choice:option.id}),revision:s.bridge.revision};
   result=await s.execute('command',cmd);assert.deepEqual(await r.execute('command',cmd),result);assert.equal(result.status,200,JSON.stringify(result.body).slice(0,1000));
   if(mode==='golem_jump' && phase===0 && s.bridge.state().input_request){const mid=await s.suspend(),cold=await make(mode);try{const check=await BattleSession.restore(cold.k.rpc,mid.build,mid);assert.deepEqual(check.bridge.state(),s.bridge.state());}finally{cold.k.dispose();s.suspended=false;}}
   if(s.bridge.state().input_request){const staleAgain={type:'input_response',input_id:input.id,cancel:true,revision:s.bridge.revision};const before=structuredClone(s.bridge.state());assert.equal((await s.execute('command',staleAgain)).status,400);assert.equal((await r.execute('command',staleAgain)).status,400);const after=s.bridge.state();assert.equal(after.input_request.id,before.input_request.id);assert.equal(after.turn,before.turn);assert.equal(after.locked,before.locked);}
   if(mode==='mastery' && !cancel && s.bridge.state().input_request){const next=s.bridge.state().input_request;const accept=next.options.find(o=>o.label.includes('Accept'));assert.ok(accept);const cmd2={type:'input_response',input_id:next.id,choice:accept.id,revision:s.bridge.revision};result=await s.execute('command',cmd2);assert.deepEqual(await r.execute('command',cmd2),result);assert.equal(result.status,200,JSON.stringify(result.body).slice(0,1000));}
  }
  assert.equal(s.bridge.state().input_request,null);const saved=await s.suspend();const restored=await make(mode);try{const check=await BattleSession.restore(restored.k.rpc,saved.build,saved);assert.deepEqual(check.bridge.state(),s.bridge.state());}finally{restored.k.dispose();}
  if(['tools','priming','mastery','empower'].includes(mode)){
   const talents=s.bridge.state().talents;const byid=id=>talents.find(t=>t.id===id);const cancelled=process.argv.includes('--cancel');
   if(mode==='tools'){assert.equal(!!byid('T_HIDDEN_BLADES'),!cancelled);assert.equal(!!byid('T_ROGUE_S_TOOLS').cooldown,!cancelled);if(!cancelled)assert.ok(byid('T_HIDDEN_BLADES').cooldown);}
   if(mode==='priming'||mode==='mastery'){assert.equal(!!byid('T_BEAR_TRAP'),!cancelled);if(!cancelled)assert.ok(byid('T_BEAR_TRAP').cooldown);}
   if(mode==='empower'){assert.equal(byid('T_EMPOWER').active,!cancelled);}
   assert.equal(s.bridge.state().last_action.energy_spent,!cancelled);
  }
  if(mode==='golem_equipment'){assert.ok(a.logs.includes('GOLEM_TAKEOFF_OK'));assert.ok(a.logs.includes('GOLEM_WEAR_OK'));}
  if(mode==='golem_equipment_cancel')assert.ok(!a.logs.includes('GOLEM_TAKEOFF_OK')); 
  if(mode.startsWith('golem')&&!mode.startsWith('golem_equipment')&&mode!=='golem_jump'){assert.ok(a.logs.includes(mode==='golem_skill'?'GOLEM_TALENT_ALLOCATED':'GOLEM_STAT_ALLOCATED'));if(mode==='golem_no')assert.ok(a.logs.includes('GOLEM_ROLLBACK_OK'));}
  if(mode==='row')assert.ok(a.logs.includes('ROW_CALLBACK_OK'));
  report.cases.push({mode,cancel:process.argv.includes('--cancel'),seen,final:s.bridge.state().last_action,pending_replay:true,completed_replay:true,stale_rejected:true});

 }catch(e){report.error={mode,message:String(e.stack||e)};report.logs=a?.logs.slice(-100);process.exitCode=1;break;}
 finally{a?.k.dispose();b?.k.dispose();}
}
report.passed=report.cases.length===modes.length;await mkdir(dirname(output),{recursive:true});await writeFile(output,JSON.stringify(report,null,2));console.log(JSON.stringify({...report,logs:undefined}));





