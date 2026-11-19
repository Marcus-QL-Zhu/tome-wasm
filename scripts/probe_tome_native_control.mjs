// Native party control and replay. Controlled cases are labelled separately.
import {readFile,writeFile,mkdir} from 'node:fs/promises';
import {resolve,dirname} from 'node:path';
import {pathToFileURL} from 'node:url';
import assert from 'node:assert/strict';
const root=resolve(process.argv[2]),output=resolve(process.argv[3]),overlay=process.argv.includes('--source');
const {createKernel}=await import(pathToFileURL(resolve(root,'kernel_runtime.mjs')));
const {BattleSession}=await import(pathToFileURL(overlay?resolve('tome_mvp/wasm/battle_session.mjs'):resolve(root,'battle_session.mjs')));
const {default:createTome}=await import(pathToFileURL(resolve(root,'tome.js')));
const bytes=await readFile(resolve(root,'tome.data')),wasmBinary=await readFile(resolve(root,'tome.wasm')),identity=JSON.parse(await readFile(resolve(root,'../identity.json'))),logs=[];
async function make(mode){return createKernel(async options=>{
 const m=await createTome(options);
 if(overlay)for(const name of ['native_control','worker','units','visibility','automation_health','formal_scene','bootstrap','ai_input_task','player_aioo'])m.FS.writeFile('/bundle/headless/'+name+'.lua',await readFile(resolve('tome_mvp/headless',name+'.lua'),'utf8'));
 if(overlay)m.FS.writeFile('/bundle/generated/probe.lua',await readFile(resolve('tome_mvp/headless/bootstrap.lua'),'utf8'));
 if(mode==='secondary_owner'){
  const config=JSON.parse(await readFile(resolve(root,'../encounter.json'),'utf8'));[config.party[0],config.party[1]]=[config.party[1],config.party[0]];
  m.FS.writeFile('/bundle/headless/encounter_config.lua',"return assert(require('json_validate').decode([==["+JSON.stringify(config)+"]==]))");
 }
 if(!['roundtrip','secondary_owner'].includes(mode)){
  const path='/bundle/headless/worker.lua',source=m.FS.readFile(path,{encoding:'utf8'});
  const fixture=String.raw`
local base=scenario.create
scenario.create=function(...)
 local s=base(...);local p=s.player;local g=assert(p.alchemy_golem);local floor=s.map(p.x,p.y,s.Map.TERRAIN)
 local wall=s.map(0,0,s.Map.TERRAIN)
 for x=1,18 do for y=1,18 do s.map(x,y,s.Map.TERRAIN,floor:clone());s.map.lites(x,y,true)end end
 local actors={p,g,s.allies[2],s.allies[3]};for _,a in ipairs(s.enemies)do actors[#actors+1]=a end
 for _,a in ipairs(actors)do s.map:remove(a.x,a.y,s.Map.ACTOR);a.x=nil;a.y=nil;a.doAI=function(self)self:useEnergy()end end
 p:move(3,10,true);g:move(4,10,true);s.allies[2]:move(2,12,true);s.allies[3]:move(3,12,true)
 for i,a in ipairs(s.enemies)do a:move(11+i,10,true)end
 if MODE=='lost_sight_rest' then
  g:learnTalent(g.T_MANA_POOL,true,1,{no_unlearn=true});g.max_mana=1000;g.mana=500;g.mana_regen=1
  for i,a in ipairs(s.enemies)do a:move(1+i,4,true)end
 end
 if MODE=='ai_reflection' or MODE=='native_ai_reflection' then
  s.enemies[1]:move(5,10,true);s.enemies[1].combat_def=-1000;g.combat_atk=1000
  s.enemies[1].on_melee_hit={[require('engine.DamageType').FIRE]=g.max_life*1000}
 end
 if MODE=='ai_roundtrip' or MODE=='ai_reject' then
  local wait=g.waitTurn
  g.waitTurn=function(self,...)
   local result=wait(self,...)
   if MODE=='ai_roundtrip' then assert(game.party:setPlayer(p));assert(game.party:setPlayer(self))
   else self.no_leave_control=true;assert(not game.party:setPlayer(p))end
   return result
  end
 end
 if MODE=='ai_input_control' or MODE=='ai_input_fault' then
  g:learnTalent(g.T_MANA_POOL,true,1,{no_unlearn=true});g.max_mana=1000;g.mana=1000
  g:learnTalent(g.T_PHASE_DOOR,true,5,{no_unlearn=true})
  local t=g:getTalentFromId(g.T_PHASE_DOOR);local action=t.action
  t.action=function(self,...)
   local result=action(self,...)
   if result then assert(game.party:setPlayer(p));if MODE=='ai_input_fault' then error('controlled_after_control_fault')end end
   return result
  end
  local post=t.post_action
  t.post_action=function(self,...)print('CONTROL_NATIVE_POST_ACTION');if post then return post(self,...)end end
 end
 if MODE=='out_of_sight' then for y=1,18 do s.map(8,y,s.Map.TERRAIN,wall:clone())end;g:move(12,12,true)end
 if MODE=='modal' then g.no_leave_control=true end
 local on_act=g.on_act
 g.on_act=function(self,...)
  if game.player==self and not self._control_probe then
   self._control_probe=true
   if MODE=='lost_sight' or MODE=='lost_sight_ai' or MODE=='lost_sight_rest' then
    for y=1,18 do s.map(8,y,s.Map.TERRAIN,wall:clone())end
    self:move(12,12,true)
   elseif MODE=='death' then self:setEffect(self.EFF_BURNING,3,{src=s.enemies[1],power=self.max_life*1000})
   elseif MODE=='owner_down' then p:takeHit(p.max_life*1000,s.enemies[1])
   elseif MODE=='all_down' then for _,a in ipairs(s.allies)do a:takeHit(a.max_life*1000,s.enemies[1])end end
  end
  if not self.dead then return on_act(self,...)end
 end
 s.map.clean_fov=true;p:doFOV();return s
end
`.replaceAll('MODE',JSON.stringify(mode));
  m.FS.writeFile(path,source.replace("local scenario = require 'scene'","local scenario = require 'scene'\n"+fixture));
 }
 if(mode.startsWith('ai_') || ['native_ai_reflection','lost_sight_ai','lost_sight_rest'].includes(mode)){
  const path='/bundle/headless/worker.lua',source=m.FS.readFile(path,{encoding:'utf8'});
  let controller=String.raw`local aioo_factory = require 'player_aioo'
local load=aioo_factory.load_source
aioo_factory.load_source=function(...)
 local c=load(...);local class=c.class
 local owner_stop=c.stop_owned
 if owner_stop then c.stop_owned=function(owner,...)
  local current=game.player;local used=current.energy.used;local energy=current.energy.value;local tid=current.ai_state.last_tid
  local result=owner_stop(owner,...)
  assert(game.player==current and current.energy.value==energy,'cleanup changed the new body energy')
  if current~=owner then assert(current.energy.used==used and current.ai_state.last_tid==tid,'cleanup wrote new body flags')end
  if owner._probe_forced_energy then
   assert(owner.energy.value==owner._probe_forced_energy,'forced action did not restore old energy')
   assert(not owner.force_talent_ignore_ressources or owner.force_talent_ignore_ressources<=0,'force resource flag leaked')
   assert(owner:getCurrentTalentMode()=='none','forced talent mode leaked')
  end
  print('CONTROL_STOP_OWNER_CLEAN');return result
 end end
 if string.sub(MODE,1,3)=='ai_' then
  class.player_ai_start=function(self)self.ai_active=true;game.player:act()end
  class.act=function()
  local actor=game.player
  if MODE=='ai_input_control' or MODE=='ai_input_fault' then
   actor._probe_forced_energy=actor.energy.value
   actor:forceUseTalent(actor.T_PHASE_DOOR,{ignore_energy=true,ignore_ressources=true})
  elseif MODE=='ai_roundtrip' or MODE=='ai_reject' then actor:waitTurn()
  else actor:attackTarget(game.level.map(5,10,require('engine.Map').ACTOR),nil,1)end
  print('CONTROL_AI_FOLLOWUP')
  game.player:waitTurn()
  end
 end
 return c
end`.replaceAll('MODE',JSON.stringify(mode));
  m.FS.writeFile(path,source.replace("local aioo_factory = require 'player_aioo'",controller));
 }
 if(process.argv.includes('--diagnose')){const path='/bundle/headless/worker.lua',source=m.FS.readFile(path,{encoding:'utf8'});m.FS.writeFile(path,source.replace("local scenario = require 'scene'",String.raw`local scenario = require 'scene'
local base=scenario.create
scenario.create=function(...)local s=base(...);local p=s.player
 print('CONTROL_DIAG',p.alchemy_golem and p.alchemy_golem.uid,p.alchemy_golem and p.alchemy_golem.x,p.alchemy_golem and p.alchemy_golem.y)
 for a,def in pairs(game.party.members)do print('CONTROL_MEMBER',a.name,a.uid,def.control,game.level:hasEntity(a),a.x,a.y)end
 return s end`));}
 return m;
},{wasmBinary,getPreloadedPackage:()=>bytes.buffer.slice(bytes.byteOffset,bytes.byteOffset+bytes.byteLength)},{log:(...v)=>{const line=v.join(' ');if(line.startsWith('CONTROL_'))report.diagnostics=(report.diagnostics||[]).concat(line);logs.push(line);if(logs.length>30)logs.shift();}});}
const report={runtime:'real Wasm',source_overlay:overlay,cases:[]};
const select=process.argv.find(v=>v.startsWith('--cases=')),seed=Number(process.argv.find(v=>v.startsWith('--seed='))?.slice(7) || 23),modes=select?select.slice(8).split(','):process.argv.includes('--initial-only')?['roundtrip']:['roundtrip','denials','out_of_sight','modal','lost_sight','death','owner_down','all_down','secondary_owner','actions'];
for(const mode of modes){let a,b;try{
 logs.length=0;
 a=await make(mode);const s=new BattleSession(a.rpc,!overlay&&mode==='roundtrip'?identity.build_id:'controlled-fixture:'+mode,seed);await s.init();const initial=s.bridge.state();
 report.initial={control:initial.control_actor_id,party:initial.party.map(p=>({id:p.id,name:p.name})),entities:initial.entities,control_targets:initial.control_targets};
 if(process.argv.includes('--initial-only')){assert.ok(initial.entities.find(a=>a.name.includes('golem')),'birth companion not on visible map');report.cases.push({mode:'construction',seed,native_companion_visible:true});}
 else if(mode==='secondary_owner'){
  assert.ok(initial.entities.find(a=>a.name.includes('golem')),'secondary Alchemist companion missing');assert.equal(initial.control_targets.length,0);report.cases.push({mode,native_companion_visible:true,ordinary_owner_control_not_bypassed:true});
 }else{
  const command=async(body,expected=200)=>{const r=await s.execute('command',{...body,revision:s.bridge.revision});assert.equal(r.status,expected,JSON.stringify(r.body).slice(0,500));return r.body;};
  if(mode==='out_of_sight'){
   assert.equal(initial.control_targets.length,0);assert.equal(initial.control_actor_id,initial.leader_id);
   report.cases.push({mode,native_LOS_denial:true});continue;
  }
  const golem=initial.control_targets.find(t=>t.name.includes('golem'));assert.ok(golem,'native golem is not controllable');
  if(mode==='denials'){
   for(const target of [initial.party[1].id,initial.enemies[0].id,999999]){await command({type:'native_control',target:String(target)},400);assert.equal(s.bridge.state().turn,initial.turn);assert.equal(s.bridge.state().control_actor_id,initial.leader_id);}
   await command({type:'ai_start',mode:'explore',budget:3});const old=s.bridge.epoch;
   await command({type:'native_control',target:String(golem.id)});assert.equal(s.bridge.authorized,false);
   assert.equal((await s.execute('command',{type:'ai_step',revision:s.bridge.revision,control_epoch:old})).status,409);
  }else await command({type:'native_control',target:String(golem.id)});
  if(['lost_sight','lost_sight_ai','lost_sight_rest'].includes(mode)){
   assert.ok(s.bridge.state().controlled_actor.effects.some(e=>e.id==='EFF_GOLEM_OFS'));
   if(mode!=='lost_sight')await command({type:'ai_start',mode:'sweep',budget:20});
   let count=0;while(s.bridge.state().control_actor_id===golem.id && count++<20)await command(mode==='lost_sight'?{type:'wait'}:{type:'ai_step',control_epoch:s.bridge.epoch});
   assert.equal(s.bridge.state().control_actor_id,initial.leader_id);assert.equal(s.bridge.state().ai_status,'stopped');report.cases.push({mode,native_return:true,waits:count});
  }else if(mode==='death'){
   let count=0;while(s.bridge.state().control_actor_id===golem.id && count++<5)await command({type:'wait'});
   assert.equal(s.bridge.state().control_actor_id,initial.leader_id);assert.equal(s.bridge.state().down_events.length,0);assert.equal(s.bridge.state().status,'active');assert.ok(!s.bridge.state().control_targets.some(t=>t.id===golem.id));report.cases.push({mode,native_death_return:true});
  }else if(mode==='owner_down'){
   let v=s.bridge.state();assert.equal(v.status,'awaiting_down_confirmation');assert.equal(v.down_events[0].actor_id,initial.leader_id);
   await command({type:'confirm_down',event_id:v.down_events[0].id,generation:v.generation});
   for(let n=0;s.bridge.state().advance_status==='pending' && n<5;n++)await command({type:'continue_pending'});
   await command({type:'takeover',target:String(initial.party[1].id)});assert.equal(s.bridge.state().control_actor_id,initial.party[1].id);report.cases.push({mode,explicit_confirmation:true,rescue_takeover:true});
  }else if(mode==='all_down'){
   assert.equal(s.bridge.state().status,'defeat');assert.equal(s.bridge.state().party.length,3);report.cases.push({mode,golem_not_extra_mission_life:true});
  }else if(mode==='ai_reflection' || mode==='native_ai_reflection'){
   await command({type:'ai_start',mode:'sweep',budget:3});await command({type:'ai_step',control_epoch:s.bridge.epoch});
   for(let i=0;mode==='native_ai_reflection' && s.bridge.state().control_actor_id===golem.id && i<2;i++)await command({type:'ai_step',control_epoch:s.bridge.epoch});
   assert.equal(s.bridge.state().control_actor_id,initial.leader_id);assert.equal(s.bridge.state().ai_status,'stopped');assert.equal(s.bridge.authorized,false);assert.ok(!logs.includes('CONTROL_AI_FOLLOWUP'));
   assert.ok(logs.includes('CONTROL_STOP_OWNER_CLEAN'));
   await command({type:'wait'});report.cases.push({mode,native_retaliation_death:true,old_AI_did_not_act_on_leader:true,manual_continuation:true});
  }else if(mode==='ai_roundtrip' || mode==='ai_reject'){
   const prior=s.bridge.state().control_change.serial;
   await command({type:'ai_start',mode:'sweep',budget:3});await command({type:'ai_step',control_epoch:s.bridge.epoch});
   assert.equal(s.bridge.state().control_actor_id,golem.id);
   if(mode==='ai_roundtrip'){assert.equal(s.bridge.state().control_change.serial,prior+2);assert.equal(s.bridge.authorized,false);assert.equal(s.bridge.state().ai_control_reason,'control_changed');assert.ok(!logs.includes('CONTROL_AI_FOLLOWUP'));}
   else{assert.equal(s.bridge.state().control_change.serial,prior);assert.equal(s.bridge.authorized,true);assert.ok(logs.includes('CONTROL_AI_FOLLOWUP'));}
   report.cases.push({mode,successful_transition_latched:mode==='ai_roundtrip',denial_not_a_transition:mode==='ai_reject'});
  }else if(mode==='ai_input_control' || mode==='ai_input_fault'){
   await command({type:'ai_start',mode:'sweep',budget:3});await command({type:'ai_step',control_epoch:s.bridge.epoch});
   let v=s.bridge.state();assert.equal(v.input_request.kind,'target');
   const doc=await s.suspend();b=await make(mode);const restored=await BattleSession.restore(b.rpc,doc.build,doc);assert.deepEqual(restored.bridge.state(),v);s.suspended=false;
   for(let phase=0;phase<2;phase++){
    v=s.bridge.state();const answer={type:'input_response',input_id:v.input_request.id,x:4,y:phase===0?10:8,revision:s.bridge.revision};
    const r=await s.execute('command',answer);assert.deepEqual(await restored.execute('command',answer),r);assert.equal(r.status,mode==='ai_input_fault'&&phase===1?500:200);
   }
   assert.ok(!logs.includes('CONTROL_AI_FOLLOWUP'));
   if(mode==='ai_input_fault'){assert.equal(s.bridge.locked,true);report.cases.push({mode,true_error_remains_unknown:true});continue;}
   assert.equal(s.bridge.state().control_actor_id,initial.leader_id);assert.equal(s.bridge.state().ai_status,'stopped');assert.ok(logs.includes('CONTROL_NATIVE_POST_ACTION'));assert.ok(logs.includes('CONTROL_STOP_OWNER_CLEAN'));
   report.cases.push({mode,two_stage_input:true,native_post_action:true,force_cleanup:true,no_AI_followup:true});
  }else if(mode==='actions'){
   const human=initial.party[0];for(let i=0;i<7;i++)await command({type:'move',dx:1,dy:0});
   const v=s.bridge.state();assert.equal(v.controlled_actor.x,11);assert.equal(v.party[0].x,human.x);assert.equal(v.party[0].y,human.y);assert.equal(v.capabilities.rescue_start,false);
   const enemy=v.enemies.find(e=>e.x===12&&e.y===10);assert.ok(enemy);const before=enemy.hp;
   for(let i=0;i<10 && s.bridge.state().enemies.find(e=>e.id===enemy.id)?.hp>=before;i++)await command({type:'attack',mode:'melee',target:String(enemy.id)});
   assert.ok(s.bridge.state().enemies.find(e=>e.id===enemy.id)?.hp<before,'no native melee hit in bounded sample');
   report.cases.push({mode,move_acts_on_golem:true,leader_does_not_move:true,native_melee_damage:true});
  }else{
   assert.equal(s.bridge.state().control_actor_id,golem.id);assert.equal(s.bridge.state().controlled_actor.id,golem.id);assert.equal(s.bridge.state().party.length,3);assert.equal(s.bridge.state().ai_status,'stopped');
   const doc=await s.suspend();b=await make(mode);const restored=await BattleSession.restore(b.rpc,doc.build,doc);assert.deepEqual(restored.bridge.state(),s.bridge.state());s.suspended=false;
   if(mode==='roundtrip'&&!overlay)await writeFile(output.replace(/\.json$/,'.controlled.archive.json'),JSON.stringify(doc));
   const back={type:'native_control',target:String(initial.leader_id),revision:s.bridge.revision},r=await s.execute('command',back);assert.deepEqual(await restored.execute('command',back),r);
   if(mode==='modal'){assert.equal(r.status,403);assert.equal(s.bridge.state().control_actor_id,golem.id);await assert.rejects(a.rpc('act',{type:'return_control'},s.bridge.generation));}
   else {assert.equal(r.status,200);assert.equal(r.body.control_actor_id,initial.leader_id);}
   if(mode==='roundtrip'){
    const reset={type:'new_game',seed:7,revision:s.bridge.revision},fresh=await s.execute('command',reset);assert.deepEqual(await restored.execute('command',reset),fresh);assert.equal(fresh.status,200);assert.equal(fresh.body.control_actor_id,fresh.body.leader_id);assert.equal(fresh.body.entities.filter(e=>e.name.includes('golem')).length,1);assert.equal(fresh.body.control_change,null);
   }
   report.cases.push({mode,same_uid:true,real_golem:true,replay:true});
  }
  if(!['roundtrip','denials','modal'].includes(mode)){const doc=await s.suspend();b?.dispose();b=await make(mode);const restored=await BattleSession.restore(b.rpc,doc.build,doc);assert.deepEqual(restored.bridge.state(),s.bridge.state());report.cases.at(-1).replay=true;}
 }
}catch(e){report.error={mode,message:String(e.stack||e)};report.logs=logs;process.exitCode=1;break;}
finally{a?.dispose();b?.dispose();}}
report.passed=!report.error;await mkdir(dirname(output),{recursive:true});await writeFile(output,JSON.stringify(report,null,2));console.log(JSON.stringify({...report,initial:undefined,logs:undefined}));
