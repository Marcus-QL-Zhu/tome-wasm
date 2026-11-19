import {readFile,writeFile,mkdir} from 'node:fs/promises';
import {resolve,dirname} from 'node:path';
import {pathToFileURL} from 'node:url';
import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
const root=resolve(process.argv[2]),output=resolve(process.argv[3]),overlay=process.argv.includes('--source');
const {createKernel}=await import(pathToFileURL(resolve(root,'kernel_runtime.mjs')));
const {BattleSession}=await import(pathToFileURL(overlay?resolve('tome_mvp/wasm/battle_session.mjs'):resolve(root,'battle_session.mjs')));
const {default:createTome}=await import(pathToFileURL(resolve(root,'tome.js')));
const bytes=await readFile(resolve(root,'tome.data')),wasmBinary=await readFile(resolve(root,'tome.wasm')),logs=[];
async function make(mode){return createKernel(async options=>{
 const m=await createTome(options);
 if(overlay)for(const name of ['native_control','rescue','worker','units','visibility','automation_health','ai_input_task','player_aioo','content_policy','native_actions','formal_factory','formal_roster','native_catalog'])m.FS.writeFile('/bundle/headless/'+name+'.lua',await readFile(resolve('tome_mvp/headless',name+'.lua'),'utf8'));
 if(overlay)m.FS.writeFile('/bundle/generated/probe.lua',await readFile(resolve('tome_mvp/headless/bootstrap.lua'),'utf8'));
 if(overlay){
  const rule='/bundle/tome/data/talents/psionic/thought-forms.lua',raw=m.FS.readFile(rule);
  const old='game.party:hasMember(p.target).control = old_control',replacement='game.party:hasMember(p.target).control = p.old_control';
  assert.equal(createHash('sha256').update(raw).digest('hex'),'7cbcd6ff95fb4427c3b1ff3fcd486851aad8a690b75ac763853fe1f00a31188d');
  const original=new TextDecoder().decode(raw);assert.equal(original.split(old).length,2);m.FS.writeFile(rule,original.replace(old,replacement));
 }
 const path='/bundle/headless/worker.lua',source=m.FS.readFile(path,{encoding:'utf8'});
 const fixture=String.raw`
if MODE=='solipsist' then
 local c=require('encounter_config')
 c.party[1]={birth={sex='Male',race='Human',subrace='Cornac',class='Psionic',subclass='Solipsist'},name='Solipsist probe',level=18,stats={},talents={}}
end
local base=scenario.create
scenario.create=function(...)
 local s=base(...);local p=s.player;local floor=s.map(p.x,p.y,s.Map.TERRAIN)
 for x=1,18 do for y=1,18 do s.map(x,y,s.Map.TERRAIN,floor:clone());s.map.lites(x,y,true)end end
 local actors={};for _,a in ipairs(s.allies)do actors[#actors+1]=a end;for _,a in ipairs(s.enemies)do actors[#actors+1]=a end
 for _,a in ipairs(actors)do s.map:remove(a.x,a.y,s.Map.ACTOR);a.x=nil;a.y=nil;a.doAI=function(self)self:useEnergy()end end
 p:move(4,10,true);s.allies[2]:move(2,10,true);s.allies[3]:move(3,10,true)
 for i,a in ipairs(s.enemies)do a:move(10+i,10,true)end
 local native_set=game.party.setPlayer
 game.party.setPlayer=function(self,target,bypass)
  local previous=game.player;local owner=previous and previous.summoner
  local oldai=owner and owner.over_mind_ai
  local active=owner and owner.T_OVER_MIND and owner:isTalentActive(owner.T_OVER_MIND)
  local saved=active and active.target==previous and {control=active.old_control,life=previous.max_life,speed=previous.combat_physspeed,damage=previous.inc_damage.all,energy=owner.energy.value}
  local result,reason=native_set(self,target,bypass)
  if MODE=='death' and previous and previous:attr('is_psychic_projection') and result then
   assert(previous.dead and previous._special_fired and previous.summon_time>0,'projection did not die before expiry')
   print('SPECIAL_PROJECTION_DEATH',previous.uid,previous.summon_time)
  end
  if saved and result then
   assert(self:hasMember(previous).control==saved.control,'thought-form control permission not restored')
   assert(owner.ai==oldai,'owner AI not restored')
   assert(not owner:isTalentActive(owner.T_OVER_MIND),'Over Mind still sustained')
   assert(previous.max_life<saved.life and previous.combat_physspeed<saved.speed and previous.inc_damage.all<saved.damage,'Over Mind bonuses not removed')
   assert(owner.energy.value==saved.energy,'Over Mind forced deactivation consumed owner energy')
   assert((owner.talents_cd[owner.T_OVER_MIND] or 0)>0,'Over Mind cooldown missing')
   print('SPECIAL_OVER_MIND_RESTORED',saved.control,owner.energy.value,saved.energy,owner.talents_cd[owner.T_OVER_MIND])
  end
  return result,reason
 end
 p:learnTalent(p.T_PSI_POOL,true,1,{no_unlearn=true});p.max_psi=1000;p.psi=1000
 for _,id in ipairs({p.T_PROJECTION,p.T_THOUGHT_FORMS,p.T_TF_WARRIOR,p.T_OVER_MIND})do p:learnTalent(id,true,3,{no_unlearn=true})end
 if MODE=='death' or MODE=='core_down' then
 local act=p.on_act
 p.on_act=function(self,...)
  if self:attr('is_psychic_projection') and not self._special_fired then
   self._special_fired=true
   if MODE=='death' then self.life=1;self:setEffect(self.EFF_BURNING,3,{src=s.enemies[1],power=5})
   else self.summoner:takeHit(self.summoner.max_life*1000,s.enemies[1]) end
  end
  if not self.dead and act then return act(self,...) end
 end
end
if MODE=='secondary' then
 local a=s.allies[2];a:learnTalent(a.T_PSI_POOL,true,1,{no_unlearn=true});a.max_psi=1000;a.psi=1000
 a:learnTalent(a.T_PROJECTION,true,3,{no_unlearn=true})
 a.doAI=function(self) if not self._special_fired then self._special_fired=true;local ok=self:forceUseTalent(self.T_PROJECTION,{ignore_energy=true});print('SPECIAL_SECONDARY_CAST',tostring(ok))
 game:onTickEnd(function()
  local target
  for _,m in ipairs(game.party.m_list)do if m.summoner==self and m:attr('is_psychic_projection') then target=m end end
  assert(target and game.party:hasMember(target),'secondary projection missing')
  local before=game.player;local result,reason=game.party:setPlayer(target)
  assert(not result and reason=='owner_not_controllable' and game.player==before,'secondary projection switch was not rejected')
  print('SPECIAL_SECONDARY_TARGET',target.uid,self.uid,target.summoner.uid,tostring(not not game.party:hasMember(target)),reason)
 end)
 end;self:useEnergy() end
end
s.map.clean_fov=true;p:doFOV();return s
end
`.replaceAll('MODE',JSON.stringify(mode));
 m.FS.writeFile(path,source.replace("local scenario = require 'scene'","local scenario = require 'scene'\n"+fixture));return m;
},{wasmBinary,getPreloadedPackage:()=>bytes.buffer.slice(bytes.byteOffset,bytes.byteOffset+bytes.byteLength)},{log:(...v)=>{logs.push(v.join(' '));if(logs.length>5000)logs.shift();}});}
const report={runtime:'real Wasm',source_overlay:overlay,fixture_override:true,cases:[]};
for(const mode of (process.argv.find(v=>v.startsWith('--cases='))?.slice(8).split(',')||['projection','thought','duration','secondary','death','core_down','solipsist'])){let a,b;try{
 logs.length=0;a=await make(mode);const s=new BattleSession(a.rpc,'special:'+mode,23);await s.init();const initial=s.bridge.state();
 async function cmd(data){let r=await s.execute('command',{...data,revision:s.bridge.revision});assert.equal(r.status,200,JSON.stringify(r.body).slice(0,2000));return r.body}
 if(mode==='secondary'){for(let i=0;i<8&&!logs.some(line=>line.includes('SPECIAL_SECONDARY_CAST'));i++)await cmd({type:s.bridge.state().advance_status==='pending'?'continue_pending':'wait'});const v=s.bridge.state();assert.equal(v.control_actor_id,initial.leader_id);assert.ok(!v.control_targets.some(t=>t.name.includes('Projection of')));assert.ok(logs.some(line=>/^SPECIAL_SECONDARY_CAST\s+true$/.test(line)),'secondary native cast missing');const found=logs.find(line=>/^SPECIAL_SECONDARY_TARGET\s/.test(line));assert.ok(found,'secondary ownership proof missing');const [,uid,owner,summoner,member,reason]=found.trim().split(/\s+/);assert.equal(owner,summoner);assert.equal(Number(owner),initial.party[1].id);assert.equal(member,'true');assert.equal(reason,'owner_not_controllable');assert.deepEqual(v.control_change,initial.control_change);const reject=await s.execute('command',{type:'native_control',target:uid,revision:s.bridge.revision});assert.equal(reject.status,400);report.cases.push({mode,after:v,owner_guard:true,secondary_target:uid,owner});continue;}
 if(['projection','duration','death','core_down','solipsist'].includes(mode)) await cmd({type:'talent',talent:'T_PROJECTION'});
 else {await cmd({type:'talent',talent:'T_TF_WARRIOR'});await cmd({type:'talent',talent:'T_OVER_MIND'});}
 let v=s.bridge.state();report.cases.push({mode,after:v});assert.notEqual(v.control_actor_id,initial.leader_id,'native switch did not occur');
 if(mode==='duration'||mode==='death'||mode==='core_down'){let n=0;while(s.bridge.state().control_actor_id!==initial.leader_id && s.bridge.state().status!=='awaiting_down_confirmation' && n++<40){const v=s.bridge.state();await cmd({type:v.advance_status==='pending'?'continue_pending':'wait'});}
 const end=s.bridge.state();if(mode==='death')assert.ok(logs.some(line=>/^SPECIAL_PROJECTION_DEATH\s/.test(line)),'projection death not observed');if(mode==='core_down'){assert.equal(end.status,'awaiting_down_confirmation');assert.equal(end.down_events[0].actor_id,initial.leader_id);}else {assert.equal(end.control_actor_id,initial.leader_id);assert.equal(end.down_events.length,0);assert.equal(end.status,'active');}
 const doc=await s.suspend();b=await make(mode);const restored=await BattleSession.restore(b.rpc,doc.build,doc);assert.deepEqual(restored.bridge.state(),s.bridge.state());report.cases.at(-1).duration_waits=n;report.cases.at(-1).replay=true;continue;}
 const doc=await s.suspend();b=await make(mode);const restored=await BattleSession.restore(b.rpc,doc.build,doc);assert.deepEqual(restored.bridge.state(),s.bridge.state());s.suspended=false;
 if(mode==='thought'){
  const action={type:'talent',talent:'T_BERSERKER',revision:s.bridge.revision};const result=await s.execute('command',action);assert.deepEqual(await restored.execute('command',action),result);assert.equal(result.status,200);assert.equal(result.body.controlled_actor.id,v.control_actor_id);assert.equal(v.talents.find(t=>t.id==='T_BERSERKER').active,true);assert.equal(result.body.talents.find(t=>t.id==='T_BERSERKER').active,false);assert.ok(result.body.talents.find(t=>t.id==='T_BERSERKER').cooldown>0);report.cases.at(-1).native_talent=true;
 }
 const back={type:'native_control',target:String(initial.leader_id),revision:s.bridge.revision};const r=await s.execute('command',back);assert.deepEqual(await restored.execute('command',back),r);assert.equal(r.status,200,JSON.stringify(r.body).slice(0,2000));
 report.cases.at(-1).after_return=s.bridge.state();report.cases.at(-1).replay=true;if(mode==='thought')assert.ok(logs.some(line=>line.includes('SPECIAL_OVER_MIND_RESTORED')),'no restoration evidence');
}catch(e){report.error={mode,message:String(e.stack||e)};report.logs=logs;process.exitCode=1;break}finally{a?.dispose();b?.dispose()}}
report.passed=!report.error;await mkdir(dirname(output),{recursive:true});await writeFile(output,JSON.stringify(report,null,2));console.log(JSON.stringify({passed:report.passed,error:report.error,cases:report.cases.map(c=>({mode:c.mode,control:c.after.control_actor_id,return:c.after_return?.control_actor_id}))}));


