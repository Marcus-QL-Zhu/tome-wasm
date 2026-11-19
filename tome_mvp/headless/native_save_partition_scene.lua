-- Partition native battle roots without inventing a second actor/item schema.
-- This module does not commit or publish: the caller owns transactional I/O.
local Registry=require 'native_partition_store'
local Partitions=require 'native_save_partition'
local M={}
local function zone_owner(area)return 'zone:'..#area..':'..area end
local function floor_owner(area,floor)return 'level:'..#area..':'..area..':'..floor end
local function ordered_keys(t)
 local r={};for k in pairs(t)do r[#r+1]=k end;table.sort(r);return r
end
local function copy_except(t,excluded)
 local r={};for k,v in pairs(t)do if not excluded[k]then r[k]=v end end;return r
end
-- Capture resident objects. Existing inactive descriptors are carried forward
-- without loading them; the host must retain their already committed blobs.
function M.capture(state,runtime,registry,writer,options)
 assert(state and state.game and state.game.party and state._dm_local_areas,'partitioned scene required')
 registry=registry or Registry.new()
 local areas=state._dm_local_areas;local catalog={};local roots={};local roots_by_owner={};local maps={};local by_map={}
 local promotions={}
 local main_map=state._plane_origin and state._plane_origin.map or state.map
 if state._plane_origin then maps[#maps+1]=state.map end
 for id,actor in pairs(state._dm_world_person_actors or {})do
  local entry=assert(state._dm_world_person_index and state._dm_world_person_index[id],'missing named actor index')
  assert(entry.actor_uid==actor.uid,'named actor UID mismatch')
  if actor.dead then entry.status='dead' end
  registry:record_party_class(actor)
  local ref=registry:ref(actor)
  local ownership=ref and registry:entry(ref)
  if ownership and ownership.owner~='hot' then
   assert(entry.wipeout_victor,'named actor already belongs to another partition')
   promotions[#promotions+1]=actor
  else registry:pin(actor,'hot') end
 end
 local area_keys=ordered_keys(areas)
 local Root=require 'native_save_partition_root'
 for _,id in ipairs(area_keys)do
  local area=areas[id];local zm=zone_owner(id)
  local a=copy_except(area,{zone=true,floors=true});a.zone_owner=zm;a.floors={}
  if area.zone then
   a.zone_ref=registry:pin(area.zone,zm);roots[#roots+1]={owner=zm,root=area.zone};roots_by_owner[zm]=area.zone
  else assert(type(area.zone_ref)=='string','missing cold native Zone reference');a.zone_ref=area.zone_ref end
  local floors=ordered_keys(area.floors)
  for _,n in ipairs(floors)do
   local slot=area.floors[n];local owner=floor_owner(id,n)
   if main_map and id==state._dm_current_area and n==state._dm_current_floor then
    assert(slot.level and slot.level.map==main_map,'active floor mismatch')
    local view=state._plane_origin or state
    slot.enemies=state.enemies;slot.terrain_memory=view.terrain_memory;slot.navigation_memory=view.navigation_memory;slot.shared_seen=view.shared_seen
    -- The original opponent is absent from this floor's live entity list
    -- while it fights on the temporary map. Keep its original owner.
    local opponent=state._plane_origin and state._plane_origin.opponent
    slot.plane_opponent=opponent or nil
    if opponent and not opponent._dm_histfig_id and not state.game.party:hasMember(opponent) then
     registry:pin(opponent,owner)
    end
   end
   if slot.level then
    local wrapper=slot._native_partition_root or Root.new(slot)
    assert(wrapper.slot==slot,'partition root bound to wrong slot');slot._native_partition_root=wrapper
    local ref=registry:pin(wrapper,owner)
    registry:pin(slot,owner);registry:pin(slot.level,owner);registry:pin(slot.level.map,owner)
    for _,key in ipairs({'enemies','terrain_memory','navigation_memory','shared_seen'})do
     local value=slot[key];if type(value)=='table' and not registry:ref(value) then registry:pin(value,owner) end
    end
    maps[#maps+1]=slot.level.map;by_map[slot.level.map]={area_id=id,floor=n,owner=owner}
    for _,entity in pairs(slot.level.entities or {})do
     if not state.game.party:hasMember(entity) and not entity._dm_histfig_id then registry:pin(entity,owner) end
    end
    roots[#roots+1]={owner=owner,root=wrapper};roots_by_owner[owner]=wrapper
    a.floors[n]={root_ref=ref,owner=owner,last_departure_days=slot.last_departure_days}
   else
    assert(type(slot.root_ref)=='string' and slot.owner==owner,'invalid cold Level descriptor')
    a.floors[n]=copy_except(slot,{level=true,enemies=true,terrain_memory=true,navigation_memory=true,shared_seen=true})
   end
  end
  catalog[id]=a
 end
 table.sort(promotions,function(a,b)return a.uid<b.uid end)
 for _,actor in ipairs(promotions)do
  require('native_partition_transfer').to_hot(actor,registry,
   assert(writer,'native function writer required for victor'),roots_by_owner,
   options and options.protected_refs,state._dm_area_outside and not state.map)
 end
 -- Determine transfers from actual native party inventories. A previously
 -- ground-owned object can move only while its source partition is resident.
 local seen_items={}
 for _,actor in ipairs(require('company_roster').members(state))do
  for slot,inv in pairs(actor.inven or {})do if type(slot)=='number' and type(inv)=='table' then
   for _,base in ipairs(inv)do base:forAllStack(function(item)
    local id=item._dm_item_id
    if not seen_items[item] then
     seen_items[item]=true
     local ref=registry:ref(item);local entry=ref and registry:entry(ref)
     if entry and entry.owner~='hot' then
      if id then
       local holder=state._dm_item_holders and state._dm_item_holders[id]
       assert(state._dm_item_objects and state._dm_item_objects[id]==item and holder and holder.kind=='actor' and holder.id==actor._dm_world_id,'native moving item holder mismatch')
      end
      require('native_partition_transfer').to_hot(item,registry,assert(writer,'native function writer required for item transfer'),roots_by_owner,options and options.protected_refs,state._dm_area_outside and not state.map)
     end
    end
   end)end
  end end
 end
 local app=copy_except(state,{Map=true,visual_emit=true,_dm_local_areas=true,_dm_ground_items=true,_dm_item_objects=true})
 app._dm_local_areas=catalog
 local ground,objects={},{};local ground_transfers={}
 for id,o in pairs(state._dm_item_objects or {})do objects[id]=o end
 for id,e in pairs(state._dm_ground_items or {})do
  if e.offline then
   assert(type(e.ref)=='string' and type(e.area_id)=='string' and type(e.floor)=='number','invalid cold ground index')
   ground[id]=copy_except(e,{item=true,map=true})
  else
   local location=e.map and by_map[e.map]
   if not e.map and e.item then
    assert(objects[id]==e.item and e.item._dm_item_id==id,'location-only native item mismatch')
    local ref=registry:ref(e.item);local entry=ref and registry:entry(ref)
    if entry and entry.owner~='hot' then
     require('native_partition_transfer').to_hot(e.item,registry,assert(writer,'native function writer required for item transfer'),roots_by_owner,options and options.protected_refs,state._dm_area_outside and not state.map)
    end
   end
   if location then
    assert(e.item and objects[id]==e.item and e.item._dm_item_id==id and e.item.uid,'native ground item identity mismatch')
    assert(require('campaign_items').on_ground(e.map,e.x,e.y,e.item,e.attached),'native ground item missing')
    local ref,owner=registry:assign(e.item,location.owner)
    if owner~=location.owner then ground_transfers[#ground_transfers+1]={item=e.item,owner=location.owner,source=owner} end
   end
   if location and e.map~=main_map then
    local ref=registry:ref(e.item)
    ground[id]={offline=true,attached=e.attached,ref=ref,uid=e.item.uid,location=e.location,area_id=location.area_id,floor=location.floor,x=e.x,y=e.y}
    objects[id]=nil
   else ground[id]=e end
  end
 end
 app._dm_ground_items=ground;app._dm_item_objects=objects
 local hot=require('native_save_root').new(state.game,world,{state=app,runtime=runtime})
 roots_by_owner.hot=hot
 for _,move in ipairs(ground_transfers)do
  assert(move.source=='hot' and roots_by_owner[move.owner],'unsupported ground ownership transfer')
  require('native_partition_transfer').to_owner(move.item,registry,assert(writer,'native function writer required for ground transfer'),roots_by_owner,options and options.protected_refs,move.owner,state._dm_area_outside and not state.map)
 end
 table.insert(roots,1,{owner='hot',root=hot})
 local data,r=Partitions.export(roots,registry,writer,{maps=maps,inspect_edge=options and options.inspect_edge,required_refs=options and options.protected_refs,resolve_required=options and options.resolve_required,allow_parked_cursor=state._dm_area_outside and not state.map,index_owner=options and options.index_owner})
 return data,r,{catalog=catalog,ground=ground,objects=objects}
end

-- Called only after the host has durably committed every supplied partition.
-- It never removes or reconstructs native ground objects.
function M.evict_inactive(state,plan)
 assert(state and state._dm_local_areas and type(plan)=='table','missing committed eviction plan')
 local active=state._dm_current_area;local floor=state._dm_current_floor;local parked=state._dm_area_outside and not state.map
 for id,area in pairs(state._dm_local_areas)do
  local saved=assert(plan.catalog[id],'missing committed area catalog')
  for n,slot in pairs(area.floors)do
   if parked or id~=active or n~=floor then area.floors[n]=assert(saved.floors[n],'missing committed floor') end
  end
  if parked or id~=active then area.zone=nil;area.zone_ref=saved.zone_ref;area.zone_owner=saved.zone_owner end
 end
 state._dm_ground_items=plan.ground;state._dm_item_objects=plan.objects
end
-- Materialize only the requested native owners. The host supplies blobs from
-- the committed manifest; errors invalidate the isolated candidate VM.
function M.materialize_zone(state,reader,area_id,options)
 local area=assert(state._dm_local_areas[area_id],'unknown area')
 options=options or {}
 if not area.zone then
  area.zone=reader:load(assert(area.zone_ref),{native=true,next_uid=assert(options.next_uid),zone_config=area.config})
 end
 return area.zone
end
function M.materialize(state,reader,area_id,floor,options)
 local area=assert(state._dm_local_areas[area_id],'unknown area')
 local slot=assert(area.floors[floor],'unknown floor')
 options=options or {}
 M.materialize_zone(state,reader,area_id,options)
 if not slot.level then
  local root=reader:load(assert(slot.root_ref),{native=true,next_uid=assert(options.next_uid),zone_config=area.config})
  assert(root and root.slot and root.slot.level and root.slot.level.map,'invalid native floor root')
  slot=root.slot
  area.floors[floor]=slot
 end
 for id,entry in pairs(state._dm_ground_items or {})do
  if entry.offline and entry.area_id==area_id and entry.floor==floor then
   local item=reader:load(entry.ref,{native=true,next_uid=assert(options.next_uid),zone_config=area.config})
   assert(item.uid==entry.uid and item._dm_item_id==id,'cold ground item identity mismatch')
   assert(require('campaign_items').on_ground(slot.level.map,entry.x,entry.y,item,entry.attached),'cold ground object missing from native map')
   assert(not state._dm_item_objects[id] or state._dm_item_objects[id]==item,'ground item already materialized elsewhere')
   state._dm_item_objects[id]=item
   state._dm_ground_items[id]={item=item,attached=entry.attached,map=slot.level.map,x=entry.x,y=entry.y,location=entry.location}
  end
 end
 return area.zone,slot
end
-- Any live external native object can be mutated by a hot operation (for
-- example an effect source). Re-emit its owner in the same transaction.
function M.materialize_live_owners(state,reader,next_uid)
 local registry=reader:registry();local live={}
 for ref,e in pairs(registry:live_entries())do
  if e.owner~='hot' and e.kind~='function' then live[e.owner]=true end
 end
 for id,area in pairs(state._dm_local_areas or {})do
  local zone_id=zone_owner(id)
  if live[zone_id] then if not area.zone then M.materialize_zone(state,reader,id,{next_uid=next_uid}) end;live[zone_id]=nil end
  for floor,slot in pairs(area.floors)do
   local owner=floor_owner(id,floor)
   if live[owner] then if not slot.level then M.materialize(state,reader,id,floor,{next_uid=next_uid}) end;live[owner]=nil end
  end
 end
 assert(not next(live),'live native object has unknown partition owner')
end
M.zone_owner=zone_owner;M.floor_owner=floor_owner
return M
