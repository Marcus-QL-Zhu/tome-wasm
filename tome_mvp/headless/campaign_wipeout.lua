-- Trusted, replayed post-defeat transformation. World deaths are committed separately.
local json=require 'json_validate'
local M={}
function M.victor(state)
 local latest
 for _,member in ipairs(state.allies)do
  if not require('rescue').is_down(member) then return end
  local event=member._mercenary_down_event_id
  if event and (not latest or event>latest._mercenary_down_event_id) then latest=member end
 end
 local uid=latest and latest._mercenary_down_source_uid
 if not uid or not state.game.level then return end
 for _,actor in pairs(state.game.level.entities)do
  if actor.uid==uid and not actor.dead and (actor.life or 0)>0 and actor:reactionToward(state.allies[1])<0 then
   return actor
  end
 end
end

function M.drop_spoils(actor,map,x,y)
 for _,item in ipairs(actor._dm_wipeout_spoils)do
  item.droppedBy=actor.name
  assert(map:addObject(x,y,item),'recovered equipment placement rejected')
 end
 actor._dm_wipeout_spoils=nil
end

function M.apply(state,world_id,location,victor_id)
 local rescue=require 'rescue'
 assert(type(world_id)=='string' and #world_id>0 and type(location)=='string' and #location>0,'scope required')
 assert(not next(state.game.__coroutines or {}),'active coroutine unsupported')
 assert(not state._dm_wipeout and #state.allies>=1 and #state.allies<=3 and not game.party.old_party,'unsupported party or repeated wipeout')
 assert(state._dm_items_world==world_id and state._dm_item_objects and state._dm_item_holders,'adopted inventory required')
 local seen={}; local participants=json.array()
 for i,a in ipairs(state.allies) do
  assert(a._dm_world_id and a._dm_origin and not seen[a._dm_world_id] and not a.dead and rescue.is_down(a),'complete bound defeat required')
  assert(game.party:hasMember(a) and game.level:hasEntity(a)==a,'party registration mismatch')
  seen[a._dm_world_id]=true
  participants[#participants+1]=json.object({person_id=a._dm_world_id,uid=a.uid,role=i==1 and 'leader' or 'member'})
 end
 local victor=victor_id and assert(M.victor(state),'verified victor no longer present')
 if victor then
  assert(type(victor_id)=='string' and #victor_id>0,'invalid victor identity')
  assert(not victor._dm_histfig_id or victor._dm_histfig_id==victor_id,'victor identity conflict')
  state._dm_world_person_index=state._dm_world_person_index or {}
  state._dm_world_person_actors=state._dm_world_person_actors or {}
  local prior=state._dm_world_person_actors[victor_id]
  assert(not prior or prior==victor,'victor actor conflict')
  if not prior then
   state._dm_world_person_actors[victor_id]=victor
   state._dm_world_person_index[victor_id]={actor_uid=victor.uid,area_id=state._dm_current_area,
     floor=state._dm_current_floor,status='alive',level=victor.level}
  end
  state._dm_world_person_index[victor_id].wipeout_victor=true
  victor._dm_histfig_id=victor_id
  victor._dm_normal_population=nil
  victor._dm_wipeout_spoils=victor._dm_wipeout_spoils or {}
 end
 local leader=state.allies[1];rescue.withdraw_leader(leader)
 if game.player~=leader then assert(game.party:setPlayer(leader,true),'leader control unavailable') end
 local leaving={}
 for _,member in ipairs(state.allies)do if member~=leader then leaving[member]=true end end
 for i=#game.party.m_list,1,-1 do
  local companion=game.party.m_list[i]
  if not leaving[companion] and leaving[companion.summoner] then
   game.party:removeMember(companion,true)
   companion:disappear()
   if game.level:hasEntity(companion) then game.level:removeEntity(companion,true) end
  end
 end
 local lost=json.array()
 for i=#state.allies,1,-1 do
  local a=state.allies[i];local slots={}
  for slot,inv in pairs(a.inven or {}) do
   if type(slot)=='number' and type(inv)=='table' and #inv>0 then slots[#slots+1]=slot end
  end
  table.sort(slots)
  for _,slot in ipairs(slots) do
   local inv=a:getInven(slot)
   local name=a.inven_def[slot].short_name
   local worn=a.inven_def[slot].is_worn or name:match('^QS_') or name=='SWIFT_HANDS'
   if worn or i~=1 then
    for pos=#inv,1,-1 do
     local o=assert(a:removeObject(slot,pos,true),'item removal rejected')
     if worn then
      local function record(item)
       local id=item._dm_item_id
       assert(id and state._dm_item_objects[id]==item and item._dm_world_id==world_id,'unregistered lost gear')
       lost[#lost+1]=json.object({item_id=id,uid=item.uid,person_id=a._dm_world_id})
       if item.tinker then
        local attached=item.tinker
        assert(attached._dm_item_id and state._dm_item_objects[attached._dm_item_id]==attached
           and attached._dm_world_id==world_id,'unregistered lost attachment')
        lost[#lost+1]=json.object({item_id=attached._dm_item_id,uid=attached.uid,person_id=a._dm_world_id})
       end
      end
      o:forAllStack(record)
      if victor then
       table.insert(victor._dm_wipeout_spoils,o)
      else
       o.droppedBy=o.droppedBy or a.name
       assert(state.map:addObject(a.x,a.y,o),'ground placement rejected')
      end
     else
      assert(leader:addObject(leader.INVEN_INVEN,o,true),'shared inventory could not hold returned item')
     end
    end
   end
  end
  if i>1 then
   game.party:removeMember(a,true);game.level:removeEntity(a,true);a.dead=true
   table.remove(state.allies,i)
  end
 end
 assert(state.player==leader and game.player==leader and leader.life==1 and #state.allies==1 and game.party:hasMember(leader),'leader withdrawal mismatch')
 state._dm_wipeout=true
 return json.object({participants=participants,lost=lost,ground=not victor and lost or json.array(),
  victor=victor and json.object({person_id=victor_id,uid=victor.uid}),leader_uid=leader.uid,leader_hp=leader.life,world_id=world_id,location=location})
end
return M
