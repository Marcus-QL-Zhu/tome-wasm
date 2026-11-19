-- Adapter around the upstream LevelupDialog rules. No desktop widgets or world simulation.
local json=require 'json_validate'
local M={}
local draft
local function actor(state,id)
 for _,a in ipairs(require('company_roster').members(state)) do if a._dm_world_id==id then return a end end
 error('unknown party actor')
end
local function available(a)
 assert(not a.dead and not require('rescue').is_down(a),'actor unavailable')
 assert(not a.in_combat,'cannot level while in combat')
 assert(not require('native_inputs').has_pending(),'native input pending')
end
local function clean(text)return tostring(text or ''):gsub('#[%w_]+#',''):gsub('#UID:[^#]+#','') end
local function can_learn(a,t)
 local ran,ok,reason=pcall(a.canLearnTalent,a,t)
 if not ran then return false,'该技能的特殊条件暂不可用。' end
 return ok,reason
end
local function init_uber(d)
 if d.uber and not d.uber_unloaded then return d.uber end
 local a=d.actor
 d.on_finish_prodigies=d.on_finish_prodigies or {}
 d.uber=setmetatable({actor=a,levelup_end_prodigies=d.on_finish_prodigies,fake_evol_attr=0,c_tut={generate=function()end},regentuttext=function()return '' end},{__index=require 'mod.dialogs.UberTalent'})
 for _,stat in ipairs({'strength','dexterity','constitution','magic','willpower','cunning'}) do a:learnTalentType('uber/'..stat,true) end
 a.is_in_uber_dialog=d.uber
 d.uber_unloaded=nil
 for tid,pending in pairs(d.on_finish_prodigies) do if pending then
  local t=a:getTalentFromId(tid)
  if t.is_class_evolution or t.is_race_evolution then d.uber.fake_evol_attr=d.uber.fake_evol_attr+1;a:attr('has_evolution',1) end
 end end
 return d.uber
end
local function prodigy_visible(a,t)
 if not t.uber or t.not_listed or not require('content_policy').allowed_talent(t.id) then return false end
 if t.requires_unlock and not (profile and profile.mod and profile.mod.allow_build[t.requires_unlock]) then return false end
 for _,pair in ipairs({{'is_class_evolution','subclass'},{'is_race_evolution','subrace'}}) do
  local condition=t[pair[1]]
  if condition and not (type(condition)=='string' and a:hasDescriptor(pair[2],condition) or type(condition)=='function' and condition(a,t)) then return false end
 end
 return true
end
function M.open(state,id)
 require 'engine.Quest'
 local a=actor(state,id);available(a)
 assert(not draft,'editor already open')
 local Class=require 'mod.dialogs.LevelupDialog'
 local d=setmetatable({actor=a,actor_dup=a:clone(),talents_changed={},talents_learned={},talent_types_learned={},stats_increased={},talents_deps={},prev_stats={}}, {__index=Class})
 d.actor_dup.uid=a.uid
 d.updateTooltip=function()end
 d.subtleMessage=function(self,title,message)self.error=clean(message or title) end
 d.simplePopup=d.subtleMessage;d.simpleLongPopup=d.subtleMessage
 d.triggerHook=function(_,data)return a:triggerHook(data) end
 a.last_learnt_talents=a.last_learnt_talents or {class={},generic={}}
 a.__hidden_talent_types=a.__hidden_talent_types or {};a.__increased_talent_types=a.__increased_talent_types or {}
 d.actor_dup.last_learnt_talents=d.actor_dup.last_learnt_talents or {class={},generic={}}
 d.actor_dup.__increased_talent_types=d.actor_dup.__increased_talent_types or {}
 a.is_dialog_talent_leveling=true;a.no_last_learnt_talents_cap=true
 for _,t in pairs(a.talents_def) do d:computeDeps(t) end
 init_uber(d)
 draft={state=state,id=id,dialog=d}
 return M.read(state,id)
end
function M.read(state,id)
 local a=actor(state,id);local d=draft and draft.state==state and draft.id==id and draft.dialog
 local out=json.object({actor_id=id,level=a.level,stats=json.array(),categories=json.array(),prodigies=json.array(),inscriptions=a.max_inscriptions or 3,can_add_inscription=(a.unused_talents_types or 0)>0 and (a.inscriptions_slots_added or 0)<2,
  points=json.object({stats=a.unused_stats or 0,class=a.unused_talents or 0,generic=a.unused_generics or 0,category=a.unused_talents_types or 0,prodigy=a.unused_prodigies or 0}),
  refund_limits=json.object({class=a:lastLearntTalentsMax('class'),generic=a:lastLearntTalentsMax('generic')})})
 for _,sid in ipairs({'str','dex','con','mag','wil','cun'}) do
  local base=a:getStat(sid,nil,nil,true)
  out.stats[#out.stats+1]=json.object({id=sid,value=a:getStat(sid),base=base,
   can_add=(a.unused_stats or 0)>0 and base<a.level*1.4+20 and not a:isStatMax(sid) and base<60+math.max(0,a.level-50),
   can_remove=d and base>d.actor_dup:getStat(sid,nil,nil,true) or false})
 end
 local types={};for tt in pairs(a.talents_types or {}) do types[#types+1]=tt end;table.sort(types)
 for _,tt in ipairs(types) do
  local def=a.talents_types_def[tt]
  if def and not def.hide and not tt:find('^uber/') and not a.__hidden_talent_types[tt] then
   local group=json.object({id=tt,name=require('localization').text(tt:gsub('/.*',''),'talent category')..' / '..require('localization').text(tostring(def.name or tt)),description=clean(require('localization').text(def.description)),known=a:knowTalentType(tt) and true or false,mastery=a:getTalentTypeMastery(tt),generic=def.generic and true or false,can_add=(a.unused_talents_types or 0)>0 and (def.min_lev or 0)<=a.level and (not a:knowTalentType(tt) or (a.__increased_talent_types[tt] or 0)<1),can_remove=d and (a:knowTalentType(tt)~=d.actor_dup:knowTalentType(tt) or (a.__increased_talent_types[tt] or 0)>(d.actor_dup.__increased_talent_types[tt] or 0)) or false,talents=json.array()})
   for _,t in ipairs(def.talents or {}) do if not t.hide and not t.no_levelup and require('content_policy').allowed_talent(t.id) then
    local ok,reason=can_learn(a,t);local rank=a:getTalentLevelRaw(t)
    local max=t.points+math.max(0,math.floor((a.level-50)/10))+(a.talents_inc_cap and a.talents_inc_cap[t.id] or 0);if t.points==1 then max=1 end
    local removable=d and rank>0 and (d:isUnlearnable(t,true) or d.actor_dup:getTalentLevelRaw(t.id)<rank)
    group.talents[#group.talents+1]=json.object({id=t.id,name=clean(t.name),rank=rank,max=max,mode=t.mode or 'activated',
     icon=tostring(t.image or (t.display_entity and t.display_entity.image) or (tostring(t.short_name or t.id):lower()..'.png')):gsub('^talents/',''),
     can_add=ok and rank<max and (a[t.generic and 'unused_generics' or 'unused_talents'] or 0)>0 or false,
     reason=clean(reason),can_remove=removable and true or false})
   end end
   out.categories[#out.categories+1]=group
  end
 end
 for _,t in pairs(a.talents_def) do if prodigy_visible(a,t) then
  local pending=d and d.on_finish_prodigies and d.on_finish_prodigies[t.id]
  local ok,reason=can_learn(a,t)
  out.prodigies[#out.prodigies+1]=json.object({id=t.id,category=t.type[1],name=clean(t.name),rank=a:knowTalent(t.id) and 1 or pending and 1 or 0,max=1,
   icon=tostring(t.image or ''):gsub('^talents/',''),reason=clean(reason),
   can_add=not pending and not a:knowTalent(t.id) and ok and (a.unused_prodigies or 0)>0 or false,can_remove=pending and true or false})
 end end
 table.sort(out.prodigies,function(x,y)return x.id<y.id end)
 return out
end
function M.describe(state,id,tid)
 local a=actor(state,id);local t=assert(a:getTalentFromId(tid),'unknown talent')
 assert(require('content_policy').allowed_talent(t.id),'talent unavailable')
 return json.object({id=t.id,name=clean(t.name),requirements=clean(a:getTalentReqDesc(t.id,1)),description=clean(a:getTalentFullDescription(t)),next_description=clean(a:getTalentFullDescription(t,1))})
end

function M.edit(state,id,op)
 assert(draft and draft.state==state and draft.id==id,'editor not open')
 local d=draft.dialog;local a=d.actor;available(a);d.error=nil
 assert(type(op)=='table' and (op.delta==1 or op.delta==-1),'invalid allocation delta')
 if op.kind=='stat' then
  assert(({str=true,dex=true,con=true,mag=true,wil=true,cun=true})[op.id],'unknown stat')
  d:incStat(op.id,op.delta)
 elseif op.kind=='talent' then
  local t=assert(a:getTalentFromId(op.id),'unknown talent')
  assert(require('content_policy').allowed_talent(t.id) and not t.uber and not t.hide and not t.no_levelup and a.talents_types[t.type[1]]~=nil,'talent outside character categories')
  d:learnTalent(t.id,op.delta==1)
 elseif op.kind=='category' then
  assert(a.talents_types[op.id]~=nil and not op.id:find('^uber/') and not a.talents_types_def[op.id].hide,'unknown category');d:learnType(op.id,op.delta==1)
 elseif op.kind=='inscription' then
  -- LevelupDialog.createDisplay's inscription purchase callback (ToME 1.7.6).
  assert(op.id=='slot' and op.delta==1 and (a.inscriptions_slots_added or 0)<2 and (a.unused_talents_types or 0)>0,'inscription purchase unavailable')
  a.unused_talents_types=a.unused_talents_types-1;a.max_inscriptions=(a.max_inscriptions or 3)+1;a.inscriptions_slots_added=(a.inscriptions_slots_added or 0)+1
 elseif op.kind=='prodigy' then
  local t=assert(a:getTalentFromId(op.id),'unknown prodigy');assert(prodigy_visible(a,t),'prodigy unavailable')
  init_uber(d)
  assert(op.delta==1 and not d.on_finish_prodigies[t.id] and not a:knowTalent(t.id) or op.delta==-1 and d.on_finish_prodigies[t.id],'invalid prodigy change')
  local before=d.on_finish_prodigies[t.id];d.uber:use({talent=t.id})
  assert(d.on_finish_prodigies[t.id]~=before,'native prodigy requirements rejected')
 else error('unknown allocation kind') end
 assert(not require('native_inputs').has_pending(),'talent requires additional native choice')
 return json.object({accepted=not d.error,reason=d.error or json.null,sheet=M.read(state,id)})
end
function M.finish(state,id)
 assert(draft and draft.state==state and draft.id==id,'editor not open')
 local d=draft.dialog;d.error=nil
 if d.uber and not d.uber_unloaded then d.uber:unload();d.uber_unloaded=true end
 assert(d:finish() and not d.error,d.error or 'native dependencies rejected')
 assert(not require('native_inputs').has_pending(),'talent requires additional native choice')
 d:unload();draft=nil
 return M.read(state,id)
end
function M.apply(state,world,req)
 assert(state._dm_items_world==world,'world mismatch')
 assert(type(req.steps)=='table' and #req.steps<=256,'invalid allocation steps')
 M.open(state,req.actor_id)
 for _,op in ipairs(req.steps) do local r=M.edit(state,req.actor_id,op);assert(r.accepted,r.reason) end
 M.finish(state,req.actor_id)
 return json.object({operation='progression',action_id=req.action_id,actor_id=req.actor_id})
end
M.read=require('localization').wrap(M.read)
M.describe=require('localization').wrap(M.describe)
return M
