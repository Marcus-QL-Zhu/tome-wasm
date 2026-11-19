-- Company actors remain in the native checkpoint when they leave the squad.
local json=require 'json_validate'
local M={}

function M.members(state)
 local result={}
 for _,actor in ipairs(state.allies or {})do result[#result+1]=actor end
 local ids={}
 for id,entry in pairs(state._dm_world_person_index or {})do
  if entry.status=='reserve'then ids[#ids+1]=id end
 end
 table.sort(ids)
 for _,id in ipairs(ids)do result[#result+1]=assert(state._dm_world_person_actors[id]) end
 return result
end

local function actor_index(state,person)
 for i,actor in ipairs(state.allies)do
  if actor._dm_world_id==person then return i,actor end
 end
end

local function put_on_squad(state,actor)
 assert(#state.allies<3,'squad full')
 actor.faction=state.allies[1].faction
 actor.ai='improved_tactical';actor.no_party_class=nil
 actor.ai_state={ai_move='move_complex',talent_in=1}
 actor.x=nil;actor.y=nil
 game.party:addMember(actor,{type='ally',control='no',orders={}})
 assert(game.party:hasMember(actor),'native squad admission failed')
 state.allies[#state.allies+1]=actor
 require('rescue').bind_party(state)
end

local function remove_from_squad(state,i,actor)
 assert(i~=1,'cannot remove commander')
 game.party:removeMember(actor)
 assert(not game.party:hasMember(actor),'native squad removal failed')
 table.remove(state.allies,i)
 if game:hasEntity(actor)then game:removeEntity(actor)end
 actor.x=nil;actor.y=nil;actor.fov=nil;actor.can_see_cache=nil
 require('rescue').bind_party(state)
end

local function return_gear(actor,leader)
 local slots={}
 for slot in pairs(actor.inven or {})do
  if type(slot)=='number' then slots[#slots+1]=slot end
 end
 table.sort(slots)
 for _,slot in ipairs(slots)do
  local items=actor:getInven(slot)
  for i=#items,1,-1 do
   local item=assert(actor:removeObject(slot,i,true))
   assert(leader:addObject(leader.INVEN_INVEN,item,true),'shared inventory could not hold returned item')
  end
 end
end

function M.apply(state,request)
 assert(state._dm_area_outside and not state.map,'company change requires a saved camp')
 assert(type(request.actor_id)=='string' and request.actor_id~=state.allies[1]._dm_world_id,'invalid companion')
 local operation,person=request.operation,request.actor_id
 assert(type(request.action_id)=='string' and #request.action_id>0,'company operation identity required')
 state._dm_loadout_actions=state._dm_loadout_actions or {}
 local source=request.source
 local signature=json.encode(json.object({operation=operation,actor_id=person,source=source and json.object({
   id=source.id,name=source.name,sex=source.sex,race=source.race,subrace=source.subrace,
   class=source.class,subclass=source.subclass,level=source.level}) or nil}))
 local prior=state._dm_loadout_actions[request.action_id]
 if prior then assert(signature==prior.signature,'company operation identity conflict');return prior.receipt end
 state._dm_world_person_index=state._dm_world_person_index or {}
 state._dm_world_person_actors=state._dm_world_person_actors or {}
 local index,actors=state._dm_world_person_index,state._dm_world_person_actors
 local slot,actor=actor_index(state,person)
 local entry=index[person]
 local added=json.array()
 if operation=='company_join'then
  assert(not slot and not (entry and entry.status=='reserve'),'already a member')
  local roster=require 'formal_roster'
  if entry then
   actor=assert(actors[person])
   assert(not actor.dead and (entry.status=='released' or entry.status=='surrendered' or entry.status=='alive'),'saved actor unavailable')
   for i=#(state.retired_enemies or {}),1,-1 do
    if state.retired_enemies[i]==actor then table.remove(state.retired_enemies,i)end
   end
   if entry.area_id then
    local area=assert(state._dm_local_areas[entry.area_id])
    local floor=assert(area.floors[entry.floor])
    assert(floor.level,'source floor must be resident')
    if floor.level:hasEntity(actor)then floor.level:removeEntity(actor,true)end
    for i=#(floor.enemies or {}),1,-1 do
     if floor.enemies[i]==actor then table.remove(floor.enemies,i)end
    end
   end
   roster.ensure_basic_equipment(actor)
  else
   local source=assert(request.source)
   actor=roster.create_auto(source)
   roster.equip_auto(actor)
   actor:resetToFull()
  end
  actor._dm_world_id=person;actor._dm_origin=actor._dm_origin or 'histfig:'..person
  actor._dm_histfig_id=person
  actors[person]=actor
  index[person]={actor_uid=actor.uid,status='reserve',level=actor.level}
  if #state.allies<3 then put_on_squad(state,actor);index[person].status='squad' end
  for _,item in ipairs(require('campaign_items').adopt(state,state._dm_items_world,state._dm_items_campaign))do
   if item.actor_id==person then added[#added+1]=item end
  end
 elseif operation=='company_squad_add'then
  assert(not slot and entry and entry.status=='reserve','not a reserve member')
  actor=assert(actors[person]);put_on_squad(state,actor);entry.status='squad'
 elseif operation=='company_squad_remove' or operation=='company_release'then
  actor=actor or entry and entry.status=='reserve' and actors[person]
  assert(actor,'not a company member')
  if slot then remove_from_squad(state,slot,actor)
  else assert(operation=='company_release','already a reserve member') end
  actor._dm_histfig_id=person
  actors[person]=actor
  local status=operation=='company_release' and 'released' or 'reserve'
  index[person]={actor_uid=actor.uid,status=status,level=actor.level}
  if status=='released'then return_gear(actor,state.allies[1])end
 else
  error('unsupported company change')
 end
 local receipt=json.object({actor_id=person,operation=operation,action_id=request.action_id,actor_uid=actor.uid,
  status=index[person].status,level=actor.level,adopted=added})
 state._dm_loadout_actions[request.action_id]={signature=signature,receipt=receipt}
 return receipt
end

return M
