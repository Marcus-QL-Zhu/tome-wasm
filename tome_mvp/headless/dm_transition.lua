-- Host-authorized reconstruction; original enemy leaves without death or loot.
local M={}
function M.apply(state,op)
 assert(type(op)=='table' and type(op.operation_id)=='string' and #op.operation_id>0 and #op.operation_id<=100,'invalid operation identity')
 if op.operation=='grant_experience'then return require('dm_progression').apply(state,op)end
 if op.operation=='spawn_enemy'then return require('scene_placement').apply(state,op)end
 assert(op.operation=='recruit' or op.operation=='surrender','unsupported DM operation')
 state.dm_transitions=state.dm_transitions or {}
 if state.dm_transitions[op.operation_id] then return state.dm_transitions[op.operation_id] end
 local boss,index
 for i,a in ipairs(state.enemies) do if tostring(a.uid)==tostring(op.target) then boss=a;index=i end end
 assert(boss and not boss.dead and state.visible[boss.uid],'target is not a visible living enemy')
 assert(not require('rescue').is_down(state.player),'controller is unconscious')
 assert(not (boss._dm_histfig_id and op.operation=='recruit'),'named actor recruitment requires world roster binding')
 local x,y,hp=boss.x,boss.y,boss.life
 local recruit
 if op.operation=='recruit' then
  recruit=boss:cloneCustom({ai_target=false,ai_state={v={ai_move='move_complex',talent_in=1}},fov=false,can_see_cache=false},function(e)return e.__CLASSNAME=='mod.class.Object' end)
  recruit.faction=state.player.faction;recruit.ai='improved_tactical';recruit.no_party_ai=nil;recruit.no_party_class=nil
  recruit.dm_source_uid=boss.uid;recruit.dead=false;recruit._mercenary_party=true
 end
 state.game.level:removeEntity(boss,true);table.remove(state.enemies,index)
 state.retired_enemies=state.retired_enemies or {};state.retired_enemies[#state.retired_enemies+1]=boss
 for _,a in pairs(state.game.level.entities) do
  if a.ai_target and a.ai_target.actor==boss then a.ai_target={} end
  if a.ai_state and a.ai_state.tactic_leash_anchor==boss then a.ai_state.tactic_leash_anchor=nil end
 end
 local result=require('json_validate').object({operation=op.operation,source_uid=boss.uid,name=boss.name,x=x,y=y,hp=hp})
 if recruit then
  -- The old boss is gone. Register the separately reconstructed teammate.
  game.party:addMember(recruit,{type='ally',control='no',orders={}})
  state.allies[#state.allies+1]=recruit;game.zone:addEntity(game.level,recruit,'actor',x,y);recruit.life=hp
  require('rescue').bind_party(state)
  assert(recruit.uid~=boss.uid and recruit.life==hp and recruit.x==x and recruit.y==y,'recruit reconstruction mismatch')
  result.ally_uid=recruit.uid
 end
 local person_id=boss._dm_histfig_id
 if person_id then
  local entry=assert(state._dm_world_person_index and state._dm_world_person_index[person_id],'missing named actor index')
  assert(state._dm_world_person_actors and state._dm_world_person_actors[person_id]==boss,'named actor mismatch')
  entry.status=recruit and 'recruited' or 'surrendered'
  if recruit then entry.actor_uid=recruit.uid;entry.level=recruit.level;state._dm_world_person_actors[person_id]=recruit end
 end
 state.dm_transitions[op.operation_id]=result
 state.resolutions=state.resolutions or {};state.resolutions[#state.resolutions+1]=result
 return result
end
return M
