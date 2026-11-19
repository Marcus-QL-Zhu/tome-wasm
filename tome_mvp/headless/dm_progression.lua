-- Native XP authority. Host rewards use gainExp; no replacement level formula.
local M={}
local json=require('json_validate')
local installed,authorized_actor=false,nil
function M.install()
 if installed then return end
 local ActorLevel=require('engine.interface.ActorLevel')
 local gain=ActorLevel.gainExp
 ActorLevel.gainExp=function(self,value)
  if self._dm_world_id and value>0 then
   if authorized_actor~=self then return end
   authorized_actor=nil
  end
  return gain(self,value)
 end
 installed=true
end
function M.snapshot(a)
 local factor=(game.state.birth or {}).exp_multiplier or 1
 assert(type(factor)=='number' and factor>0,'invalid XP multiplier')
 return json.object({exp=a.exp or 0,exp_mod=a.exp_mod or 1,
  xp_unit=a:getExpChart(a.level>=50 and 50 or a.level+1)/factor,
  class_points=a.unused_talents or 0,generic_points=a.unused_generics or 0,
  stat_points=a.unused_stats or 0})
end
function M.apply(state,op)
 local safe=true
 if not state.campaign_bootstrap and not state._dm_wipeout then
  for _,foe in ipairs(state.enemies)do if not foe.dead then safe=false end end
 end
 assert(safe,'XP delivery requires safe campaign boundary')
 assert(type(op.awards)=='table' and #op.awards<=100,'invalid XP awards')
 state.dm_transitions=state.dm_transitions or {}
 if state.dm_transitions[op.operation_id] then return state.dm_transitions[op.operation_id] end
 local members={};for _,a in ipairs(require('company_roster').members(state))do members[a._dm_world_id]=a end
 local seen={};local tasks={}
 for _,award in ipairs(op.awards)do
  local a=members[award.person_id]
  assert(a and not a.dead and not seen[a],'unknown or repeated XP recipient')
  assert(type(award.amount)=='number' and award.amount==award.amount and award.amount>=0 and award.amount<=1000000000,'invalid XP amount')
  seen[a]=true;tasks[#tasks+1]={actor=a,amount=award.amount}
 end
 local turn=game.turn;local results=json.array()
 for _,task in ipairs(tasks)do
  local a=task.actor;local before=M.snapshot(a);local level=a.level
  if a.level<50 and task.amount>0 then
   -- Native quiet mode skips informational level popups and UI sound callbacks.
   -- Stat/talent/prodigy points and rule callbacks remain owned by Actor.levelup.
   local silent=a.silent_levelup
   a.silent_levelup=true
   authorized_actor=a
   local ok,err=pcall(a.gainExp,a,task.amount)
   authorized_actor=nil
   a.silent_levelup=silent
   assert(ok,err)
  end
  results[#results+1]=json.object({person_id=a._dm_world_id,amount=task.amount,
   before_level=level,level=a.level,before=before,after=M.snapshot(a),capped=level>=50})
 end
 assert(game.turn==turn,'XP delivery advanced combat time')
 local receipt=json.object({operation_id=op.operation_id,awards=results})
 state.dm_transitions[op.operation_id]=receipt
 return receipt
end
return M
