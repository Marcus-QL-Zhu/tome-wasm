-- Operations on native Levels. The caller owns durable save/rollback and clocks.
local M={}

-- ToME may identify a gem before stacking consumes the newly created object.
-- The native identification callback writes lore only for uniques or on_id_lore.
function M.inert_identification(info,item)
 return info.source=='@/mod/class/Object.lua' and info.linedefined==2509 and info.lastlinedefined==2517
  and info.nups==1 and item and item.__CLASSNAME=='mod.class.Object' and not item.unique and not item.on_id_lore
end

local function populate_scoped(state,level,zone,before,fn,first_uid)
 local g=state.game;local turn=g.turn;local controlled=g.player
 assert(not (g.on_tick_end and next(g.on_tick_end.fcts)) and not g.on_tick_end_custom,'generation requires empty native callback queues')
 local energy,life={},{},{};for _,a in ipairs(state.allies)do energy[a]=a.energy.value;life[a]=a.life end
 first_uid=first_uid or require('engine.Entity').native_uid_state()
 local captured={};g:onTickEndCapture(captured)
 local old_finish=rawget(zone,'finishEntity');local native_finish=zone.finishEntity;local precursors={}
 zone.finishEntity=function(z,lev,kind,input,...)
  local out=native_finish(z,lev,kind,input,...)
  if z==zone and lev==level and kind=='actor' and type(input)=='table' and type(out)=='table' and input~=out and input.__CLASSNAME=='mod.class.NPC' and out.__CLASSNAME=='mod.class.NPC' and type(input.uid)=='number' and input.uid>=first_uid and type(out.uid)=='number' and out.uid>=first_uid and not before[input] and not before[out] and input~=g.player and out~=g.player and not g.party:hasMember(input) and not g.party:hasMember(out) then precursors[input]=out end
  return out
 end
 local ok,err=xpcall(function()
  fn();rawset(zone,'finishEntity',old_finish)
  local new_objects={}
  local function add_item(o)
   if type(o)~='table' or new_objects[o] then return end
   if o.__CLASSNAME~='mod.class.Object' or type(o.uid)~='number' or o.uid<first_uid then return end
   new_objects[o]=true
   if type(o.__original)=='table' then add_item(o.__original) end
   for _,ego in ipairs(o.ego_list or {})do if type(ego)=='table' and type(ego[1])=='table' then add_item(ego[1]) end end
  end
  for _,a in pairs(level.entities)do if not before[a] and a~=g.player and not g.party:hasMember(a) and a.inven then
   for slot,inv in pairs(a.inven)do if type(slot)=='number' and type(inv)=='table' then
    for _,item in ipairs(inv)do if item.forAllStack then item:forAllStack(add_item) else add_item(item) end end
   end end
  end end
  if level.vaults_list then
   local map=level.map
   for x=0,map.w-1 do for y=0,map.h-1 do
    if map.attrs(x,y,'vault_id') then
     for i=1,map:getObjectTotal(x,y)do
      local item=map:getObject(x,y,i)
      if item._dm_vault_loot then item:forAllStack(add_item) end
     end
    end
   end end
  end
  local function check_boundary()
   assert(g.level==level and g.zone==zone and state.map==level.map and g.player==controlled and g.turn==turn,'generation callback changed scene or time')
   for a,value in pairs(energy)do assert(a.energy.value==value and a.life==life[a],'generation callback changed party') end
   assert(not next(g.__coroutines) and not require('native_inputs').has_pending() and not require('rule_events').has_pending(),'generation callback suspended')
  end
  check_boundary()
  local count=0
  for batch=1,10 do
   assert(not (g.on_tick_end and next(g.on_tick_end.fcts)),'ordinary callback escaped generation capture')
   if #captured.fcts==0 then check_boundary();return end
   count=count+#captured.fcts;assert(count<=128,'too many generation callbacks')
   local prior={}
   for _,f in ipairs(captured.fcts)do
    local _,info=require('native_function_env').catalog_prototype(f);prior[f]=true
    local seen,count_nodes={},0;local found=false
    local function inspect(v,depth)
     if type(v)~='table' or seen[v] then return end
     if native_catalog_anchor_enabled and require('native_catalog_anchor').is_catalog_container(v) then return end
     seen[v]=true;count_nodes=count_nodes+1;assert(count_nodes<=256 and depth<=4,'unbounded generation callback capture')
     if v.__CLASSNAME and v.act and v.reactionToward then
      local placed=level:hasEntity(v)==v;local successor=precursors[v]
      assert(not before[v] and type(v.uid)=='number' and v.uid>=first_uid and (placed or (successor and level:hasEntity(successor)==successor)) and v~=g.player and not g.party:hasMember(v),'generation callback references old actor')
      found=true;return
     end
     if v.__CLASSNAME=='mod.class.Object' then
      assert(new_objects[v] or type(v.uid)=='number' and v.uid>=first_uid and M.inert_identification(info,v),'generation callback references old object')
      found=true;return
     end
     if v.__CLASSNAME then return end
     for k,x in pairs(v)do if k=='self' or k=='src' or k=='target' or k=='actor' or type(k)=='number' then inspect(x,depth+1) end end
    end
    for i=1,info.nups do local _,v=debug.getupvalue(f,i);inspect(v,0) end
    assert(found,'generation callback lacks new actor provenance '..tostring(info.source)..':'..tostring(info.linedefined))
   end
   g:onTickEndExecute()
   for _,f in ipairs(captured.fcts)do assert(not prior[f],'generation callback requested a later frame')end
   check_boundary()
  end
  error('generation callback batch limit')
 end,debug.traceback)
 g:onTickEndCapture(nil);rawset(zone,'finishEntity',old_finish)
 if not ok then error(err) end
end

-- Apply the same native generation boundary to a single host-created actor.
function M.populate_scoped(state,fn)
 local level,zone=assert(state.game.level),assert(state.game.zone)
 local before={};for _,actor in pairs(level.entities)do before[actor]=true end
 local result
 populate_scoped(state,level,zone,before,function() result=fn() end)
 return result
end

-- Preserve the exact scheduler position of a native paused Level while its
-- party is removed. Only a cursor validated before departure gets this tag.
local function prepare_departure_cursor(g,level)
 local cursor=level.last_iteration
 if not cursor then level._native_parked_cursor=nil;return nil end
 assert(g.paused and g.level==level and type(cursor)=='table','unsettled native departure cursor')
 local tagged=level._native_parked_cursor==cursor
 assert(type(cursor.i)=='number' and cursor.i==math.floor(cursor.i) and cursor.i>=(tagged and 0 or 1) and cursor.i<=#level.e_array and cursor.e and cursor.e.__CLASSNAME and cursor.e.uid,'invalid native departure cursor')
 if not tagged then assert(level.e_array[cursor.i]==cursor.e,'invalid active native cursor') end
 for key in pairs(cursor)do assert(key=='i' or key=='e','unknown native cursor field') end
 return cursor,cursor.e
end
local function finish_departure_cursor(level,cursor,original_e)
 if not cursor then return end
 assert(level.last_iteration==cursor and cursor.e==original_e and cursor.i>=0 and cursor.i<=#level.e_array,'native departure changed cursor identity')
 level._native_parked_cursor=cursor
end

local function protected(actor,party)
 return (party and party:hasMember(actor)) or actor.unique or actor.randboss or actor._dm_world_id or actor._dm_origin
  or actor._dm_histfig_id or actor._dm_named or actor._dm_recruited
end

-- Only actors positively tagged by native_zone.populate are replaceable.
-- This deliberately leaves older untagged saves untouched.
function M.refresh(zone,level,player,state,before)
 assert(game.level==level and game.zone==zone,'refresh requires the active native level and zone')
 assert(zone._project_reference_level,'fresh reference level required')
 local retired={}
 for _,actor in pairs(level.entities)do
  if actor._dm_normal_population and not protected(actor,game.party) then retired[#retired+1]=actor end
 end
 table.sort(retired,function(a,b)return a.uid<b.uid end)
 for _,actor in ipairs(retired)do level:removeEntity(actor,true)end
 assert(not (game.on_tick_end and next(game.on_tick_end.fcts)) and not game.on_tick_end_custom,'retired population queued callbacks')
 local enemies,info
 populate_scoped(state,level,zone,before,function()enemies,info=require('native_zone').populate(zone,{level=level,map=level.map,spots=level.spots},player,true)end)
 return enemies,info,#retired
end

-- Caller must enforce the strictly-greater-than-one-year floor policy and
-- supply a reference computed from the live party. Run only in a disposable
-- or rollback-capable VM: generator and callbacks can fail after mutation.
function M.refresh_active(state,params)
 local g=state.game
 local ref=params.reference_level
 assert(type(ref)=='number' and ref==math.floor(ref) and ref>=1 and ref<=150,'invalid reference level')
 assert(state._dm_local_areas and state._dm_current_area,'area not bound')
 assert(not next(g.__coroutines) and not require('native_inputs').has_pending() and not require('rule_events').has_pending(),'pending native action')
 assert(not (g.on_tick_end and next(g.on_tick_end.fcts)) and not (g.on_tick_end_custom and next(g.on_tick_end_custom.fcts)),'pending callbacks')
 local level,zone=g.level,g.zone
 local slot=state._dm_local_areas[state._dm_current_area].floors[state._dm_current_floor]
 assert(slot.level==level,'active floor mismatch')
 for _,a in pairs(level.entities)do
  if a.__CLASSNAME and a.life and a.reactionToward and a:reactionToward(state.player)<0 then
   assert(a._dm_normal_population or protected(a,g.party),'unknown hostile population provenance')
  end
 end
 zone._project_reference_level=ref
 if params.loot_reference_level~=nil then require('native_zone').set_loot_reference(zone,params.loot_reference_level) end
 g:applyDifficulty(zone,ref)
 local before={};for _,a in pairs(level.entities)do before[a]=true end
 local _,_,removed=M.refresh(zone,level,state.player,state,before)
 local enemies={}
 for _,actor in pairs(level.entities)do
  if not before[actor] and actor.__CLASSNAME and actor.life and not actor._dm_vault_guardian then actor._dm_normal_population=true end
  if actor.__CLASSNAME and actor.life and actor~=state.player and actor.reactionToward and actor:reactionToward(state.player)<0 then enemies[#enemies+1]=actor end
 end
 table.sort(enemies,function(a,b)return a.uid<b.uid end)
 slot.enemies=enemies;state.enemies=enemies;state.enemy=enemies[1]
 return {area_id=state._dm_current_area,floor=state._dm_current_floor,removed=removed,enemies=#enemies,reference_level=ref,turn=g.turn}
end

-- In-memory Level slots are native Level objects, never copies of their maps.
-- Persistence must serialize the entire native object graph, not this table as JSON.
function M.get_floor(area,index,create)
 assert(type(index)=='number' and index==math.floor(index) and index>=1 and index<=area.floor_count,'floor outside area')
 assert(type(area.floors)=='table' and type(create)=='function','invalid area state')
 if not area.floors[index] then
  local level=create(index)
  assert(level and level.map,'floor creation must return native Level')
  area.floors[index]=level
 end
 return area.floors[index]
end

-- Bind the scene already constructed by formal_scene as floor one. Area IDs
-- come from the trusted host, which must validate world, campaign and tile.
function M.bind(state,params)
 assert(not state._dm_local_areas,'area state already bound')
 assert(type(params.area_id)=='string' and #params.area_id>0,'missing area identity')
 local count=params.floor_count or 1
 assert(type(count)=='number' and count==math.floor(count) and count>=1 and count<=20,'invalid floor count')
 local slot={level=state.game.level,entry={x=state.player.x,y=state.player.y},enemies=state.enemies,
  terrain_memory=state.terrain_memory,navigation_memory=state.navigation_memory,shared_seen=state.shared_seen}
 state._dm_local_areas={[params.area_id]={zone=state.game.zone,floor_count=count,floors={[1]=slot}}}
 state._dm_current_area=params.area_id;state._dm_current_floor=1
 return {area_id=params.area_id,floor=1,floor_count=count}
end

function M.transition(state,params)
 local g=state.game
 local areas=assert(state._dm_local_areas,'bind initial area first')
 assert(type(params.area_id)=='string' and #params.area_id>0,'missing area identity')
 local index=params.floor
 assert(type(index)=='number' and index==math.floor(index) and index>=1,'invalid floor')
 assert(not next(g.__coroutines) and not require('native_inputs').has_pending() and not require('rule_events').has_pending(),'pending native action')
 assert(not (g.on_tick_end and next(g.on_tick_end.fcts)) and not (g.on_tick_end_custom and next(g.on_tick_end_custom.fcts)),'pending callbacks')
 local area=areas[params.area_id]
 if area then
  assert(not params.config,'existing area cannot be reconstructed')
 else
  local config=assert(params.config,'new area requires configuration')
  assert(config.zone and config.map and config.map.size==64,'new area requires native 64x64 Zone')
  local count=config.zone.floor_count or 1
  assert(type(count)=='number' and count==math.floor(count) and count>=1 and count<=20,'invalid floor count')
  assert(config.map.kind~='forest' or count==1,'forest must have one floor')
  area={floor_count=count,config=config,floors={}}
 end
 assert(index<=area.floor_count,'floor outside area')
 if g.level and params.area_id==state._dm_current_area and index==state._dm_current_floor then return {area_id=params.area_id,floor=index,unchanged=true} end
 local previous=assert(areas[state._dm_current_area]).floors[state._dm_current_floor]
 local old=g.level
 local parked=not old and state._dm_area_outside
 assert(parked or previous.level==old,'active floor mismatch')
 local controlled_core=false
 for _,actor in ipairs(state.allies)do if actor==state.player then controlled_core=true end end
 assert(state.player==g.player and controlled_core,'unsupported controlled auxiliary actor')
 assert(parked or not g.to_re_add_actors or not next(g.to_re_add_actors),'unfinished native party transition')
 for _,actor in ipairs(g.party.m_list)do
  assert(parked or old:hasEntity(actor)==actor,'party member is not on source level')
  if actor==state.player then assert(not g.party:hasMember(actor).temporary_level,'temporary player cannot change level') end
 end
 local departure_cursor,departure_e
 if not parked then departure_cursor,departure_e=prepare_departure_cursor(g,old) end
 local oldzone=g.zone
 if not parked then
 previous.entry={x=state.player.x,y=state.player.y}
 previous.terrain_memory=state.terrain_memory;previous.navigation_memory=state.navigation_memory;previous.shared_seen=state.shared_seen
 end
 local turn=g.turn
 -- Apply the same party and player rules as native Game:changeLevelReal.
 if not parked then g.party:leftLevel(params.area_id==state._dm_current_area) end
 assert(g.player==state.player and g.party:hasMember(state.player),'party leave changed controlled actor')
 local destination_zone=area.zone or require('native_zone').template(area.config.zone,area.config.map.kind)
 if not parked and oldzone.on_leave then
  local nl,nz,stop=oldzone.on_leave(index,old.level,destination_zone)
  assert(not stop and (not nl or nl==index) and (not nz or nz==destination_zone),'zone redirected or rejected transition')
 end
 if not parked then state.player:onLeaveLevel(oldzone,old) end
 assert(not next(g.__coroutines) and not require('native_inputs').has_pending() and not require('rule_events').has_pending(),'leave callback suspended')
 assert(not (g.on_tick_end and next(g.on_tick_end.fcts)) and not (g.on_tick_end_custom and next(g.on_tick_end_custom.fcts)),'leave callback queued work')
 -- Native leave records the exact remaining party members for reattachment.
 if not parked then g:leaveLevel(old,index,old.level);finish_departure_cursor(old,departure_cursor,departure_e) end
 local travelling={state.player}
 for _,actor in ipairs(g.party.m_list)do
  if actor~=state.player then
   assert(g.to_re_add_actors and g.to_re_add_actors[actor],'party member absent from native reattachment queue')
   travelling[#travelling+1]=actor
  end
 end
 for actor in pairs(g.to_re_add_actors or {})do assert(g.party:hasMember(actor),'unexpected native reattachment actor') end
 -- Other actors remain in the stored Level but must not act off-floor.
 if not parked then for _,entity in pairs(old.entities)do if g:hasEntity(entity)then g:removeEntity(entity)end end end
 if not area.zone then
  require('native_zone').ensure_campaign()
  -- The upstream last-zone cache is keyed by template, not campaign area ID.
  -- Keep existing area objects in our table and create a distinct new Zone.
  local template=require('native_zone').template(area.config.zone,area.config.map.kind)
  require('mod.class.Zone'):removeLastPersistZone(template)
  area.zone=require('formal_factory').new_zone(area.config)
 end
 g.zone=area.zone
 local slot=area.floors[index]
 local created=false
 local first_uid
 if not slot then
  first_uid=require('engine.Entity').native_uid_state()
  local generated=require('formal_map').create(area.zone,state.player,area.config,index)
  slot={level=generated.level,entry=generated.entry,generated=generated}
  area.floors[index]=slot;created=true
 end
 g.level=slot.level
 local map=slot.level.map
 for _,entity in pairs(slot.level.entities)do if not g:hasEntity(entity)then g:addEntity(entity)end end
 map:setViewerActor(state.player)
 require('native_actions').install_visual_adapter(map)
 local positions={}
 for y=1,map.h-2 do for x=1,map.w-2 do
  local terrain=map(x,y,state.Map.TERRAIN)
  if terrain and not map.attrs(x,y,'vault_id') and not terrain:check('block_move',x,y,state.player,false,false) and not map(x,y,state.Map.ACTOR) then
   positions[#positions+1]={x=x,y=y,d=math.abs(x-slot.entry.x)+math.abs(y-slot.entry.y)}
  end
 end end
 table.sort(positions,function(a,b)if a.d~=b.d then return a.d<b.d end if a.y~=b.y then return a.y<b.y end return a.x<b.x end)
 assert(#positions>=#travelling,'no room for party on destination floor')
 for i,actor in ipairs(travelling)do
  actor.x=nil;actor.y=nil;actor.fov=nil;actor.can_see_cache=nil;actor.fov_computed=nil;actor.fov_last_x=nil;actor.fov_last_y=nil
  if actor.ai_state then actor.ai_state.tactic_leash_anchor=nil;actor.ai_state.path=nil end
  actor:move(positions[i].x,positions[i].y,true);slot.level:addEntity(actor)
  assert(slot.level:hasEntity(actor)==actor and map(actor.x,actor.y,state.Map.ACTOR)==actor,'party placement failed')
  if actor~=state.player and actor.setTarget then actor:setTarget(nil) end
 end
 g.to_re_add_actors=nil
 state.map=map
 if created then
  local before={};for _,actor in pairs(slot.level.entities)do before[actor]=true end
  populate_scoped(state,slot.level,area.zone,before,function()require('native_zone').populate(area.zone,slot.generated,state.player)end,first_uid)
  slot.enemies={}
  for _,actor in pairs(slot.level.entities)do
   if not before[actor] and actor.__CLASSNAME and actor.life and not actor._dm_vault_guardian then actor._dm_normal_population=true end
   if actor.__CLASSNAME and actor.life and actor~=state.player and actor.reactionToward and actor:reactionToward(state.player)<0 then slot.enemies[#slot.enemies+1]=actor end
  end
  table.sort(slot.enemies,function(a,b)return a.uid<b.uid end)
  slot.generated=nil
 end
 if area.zone.on_enter then area.zone.on_enter(index,parked and state._dm_parked_level_number or old.level,destination_zone) end
 state.player:onEnterLevel(area.zone,slot.level)
 for _,actor in pairs(slot.level.entities)do
  if actor.removeEffectsFilter then actor:removeEffectsFilter(actor,function(effect)return effect.zone_wide_effect end,nil,nil,true) end
 end
 for _,actor in pairs(slot.level.entities)do if actor.setEffect then
  if slot.level.data.zero_gravity then actor:setEffect(actor.EFF_ZERO_GRAVITY,1,{}) else actor:removeEffect(actor.EFF_ZERO_GRAVITY,nil,true) end
  for _,effect in ipairs(slot.level.data.effects or {})do actor:setEffect(effect,1,{}) end
 end end
 slot.level.data.effects_allow=true
 state.player:onEnterLevelEnd(area.zone,slot.level)
 assert(not next(g.__coroutines) and not require('native_inputs').has_pending() and not require('rule_events').has_pending(),'entry callback suspended')
 assert(not (g.on_tick_end and next(g.on_tick_end.fcts)) and not (g.on_tick_end_custom and next(g.on_tick_end_custom.fcts)),'entry callback queued work')
 areas[params.area_id]=area
 state._dm_current_area=params.area_id;state._dm_current_floor=index;state._dm_parked_level_number=nil
 state.map=map;state.enemies=slot.enemies;state.enemy=state.enemies[1];state.visual_emit=map.particleEmitter
 state.terrain_memory=slot.terrain_memory or {};state.navigation_memory=slot.navigation_memory or {};state.shared_seen=slot.shared_seen or {};state.visible={}
 slot.terrain_memory=state.terrain_memory;slot.navigation_memory=state.navigation_memory;slot.shared_seen=state.shared_seen
 state.last_action=nil;state.resolutions={}
 map.clean_fov=true;state.player:doFOV()
 assert(g.turn==turn,'floor transition advanced time')
 return {area_id=params.area_id,floor=index,floor_count=area.floor_count,created=created,turn=g.turn}
end

local function clock_days(clock)
 assert(type(clock)=='table' and type(clock.world_tick)=='number' and clock.world_tick>=0 and clock.world_tick==math.floor(clock.world_tick),'invalid world tick')
 local day=clock.day_in_quarter
 assert(type(day)=='number' and day>=0 and day<90 and day*2==math.floor(day*2),'invalid quarter day')
 return clock.world_tick*90+day
end

function M.depart(state,params)
 local now=clock_days(params.world_clock)
 assert(state._dm_local_areas and state._dm_current_area,'area not bound')
 assert(not state._dm_last_area_clock or now>=state._dm_last_area_clock,'world clock moved backwards')
 if state._dm_area_outside then
  return {area_id=state._dm_current_area,floor=state._dm_current_floor,unchanged=true}
 end
 local slot=assert(state._dm_local_areas[state._dm_current_area].floors[state._dm_current_floor])
 slot.last_departure_days=now
 state._dm_area_outside=true;state._dm_last_area_clock=now
 return {area_id=state._dm_current_area,floor=state._dm_current_floor,departed=true}
end

-- Partition-mode departure. Only run inside an isolated candidate which will
-- either be committed with all dirty native fragments or discarded.
function M.park(state,params)
 if state._dm_area_outside and not state.game.level then return M.depart(state,params) end
 local g=state.game;local old=assert(g.level,'native level not resident')
 local zone=assert(g.zone,'native zone not resident')
 assert(state.map==old.map and state.player==g.player,'native scene mismatch')
 assert(not next(g.__coroutines) and not require('native_inputs').has_pending() and not require('rule_events').has_pending(),'pending native action')
 assert(not (g.on_tick_end and next(g.on_tick_end.fcts)) and not (g.on_tick_end_custom and next(g.on_tick_end_custom.fcts)),'pending callbacks')
 assert(not g.to_re_add_actors or not next(g.to_re_add_actors),'unfinished native party transition')
 assert(not zone.on_leave,'unsupported native zone on_leave to camp')
 local slot=assert(state._dm_local_areas[state._dm_current_area]).floors[state._dm_current_floor]
 assert(slot.level==old,'active floor mismatch')
 local turn=g.turn
 local departure_cursor,departure_e=prepare_departure_cursor(g,old)
 state._dm_parked_level_number=old.level
 slot.entry={x=state.player.x,y=state.player.y}
 slot.terrain_memory=state.terrain_memory;slot.navigation_memory=state.navigation_memory;slot.shared_seen=state.shared_seen
 g.party:leftLevel(true)
 assert(g.player==state.player and g.party:hasMember(state.player),'party leave changed controlled actor')
 state.player:onLeaveLevel(zone,old)
 assert(not next(g.__coroutines) and not require('native_inputs').has_pending() and not require('rule_events').has_pending(),'leave callback suspended')
 assert(not (g.on_tick_end and next(g.on_tick_end.fcts)) and not (g.on_tick_end_custom and next(g.on_tick_end_custom.fcts)),'leave callback queued work')
 g:leaveLevel(old,old.level,old.level)
 finish_departure_cursor(old,departure_cursor,departure_e)
 for _,actor in ipairs(g.party.m_list)do
  actor.fov=nil;actor.can_see_cache=nil;actor.fov_computed=nil;actor.fov_last_x=nil;actor.fov_last_y=nil
 end
 for _,entity in pairs(old.entities)do if g:hasEntity(entity)then g:removeEntity(entity)end end
 local result=M.depart(state,params)
 g.level=nil;g.zone=nil
 state.map=nil;state.visual_emit=nil;state.enemies={};state.enemy=nil;state.observed_actors={};state.combatants={};state.auxiliaries={};state.visible={};state.player_visible={}
 state.terrain_memory=nil;state.navigation_memory=nil;state.shared_seen=nil
 assert(g.turn==turn,'native camp departure advanced time')
 return result
end

-- Host authenticates area identity/tile and supplies the authoritative clock.
-- Any failure invalidates this VM; commit only a fully verified candidate.
function M.enter(state,params)
 local now=clock_days(params.world_clock)
 assert(type(params.area_id)=='string' and #params.area_id>0 and params.area_id~='__temporary_scene__','invalid area ID')
 assert(not state._dm_last_area_clock or now>=state._dm_last_area_clock,'world clock moved backwards')
 if not state._dm_local_areas then M.bind(state,{area_id='__temporary_scene__',floor_count=1}) end
 local areas=state._dm_local_areas
 local source=areas[state._dm_current_area]
 local source_slot=source.floors[state._dm_current_floor]
 local target=areas[params.area_id]
 if params.tile_id~=nil then
  assert(type(params.tile_id)=='string' and #params.tile_id>0,'invalid world tile')
  if target and target.tile_id then assert(target.tile_id==params.tile_id,'area world tile mismatch') end
 end
 local same_area=state._dm_current_area==params.area_id
 if same_area and state._dm_current_floor==params.floor and not state._dm_area_outside then
  state._dm_last_area_clock=now
  return {area_id=params.area_id,floor=params.floor,unchanged=true,refreshed=false}
 end
 if target then
  assert(not params.config,'existing area cannot be reconstructed')
  assert(not params.floor_count or params.floor_count==target.floor_count,'floor count mismatch')
 else
  assert(params.config and params.config.zone,'new area requires config')
  assert(params.floor_count==params.config.zone.floor_count,'floor count mismatch')
 end
 if source_slot.last_departure_days then assert(now>=source_slot.last_departure_days,'world clock moved backwards') end
 local target_slot=target and target.floors[params.floor]
 if target_slot and target_slot.last_departure_days then assert(now>=target_slot.last_departure_days,'world clock moved backwards') end
 local needs_refresh=not not (target_slot and target_slot.last_departure_days and now-target_slot.last_departure_days>360)
 if needs_refresh then
  assert(type(params.reference_level)=='number' and params.reference_level>=1 and params.reference_level<=150 and params.reference_level==math.floor(params.reference_level),'refresh requires reference level')
 end
 local result=M.transition(state,{area_id=params.area_id,floor=params.floor,config=params.config})
 target=areas[params.area_id]
 if params.tile_id~=nil then target.tile_id=params.tile_id;state.map._dm_world_location=params.tile_id end
 if not state._dm_area_outside then source_slot.last_departure_days=now end
 if needs_refresh then
  result.refresh=M.refresh_active(state,{reference_level=params.reference_level,loot_reference_level=params.loot_reference_level})
  result.refreshed=true
 else result.refreshed=false end
 state._dm_last_area_clock=now;state._dm_area_outside=false
 return result
end
function M.describe(state)
 local json=require 'json_validate'
 local areas=json.object({})
 for id,area in pairs(state._dm_local_areas or {})do
  if id~='__temporary_scene__'then
   local floors=json.object({})
   for index,slot in pairs(area.floors)do
    floors[tostring(index)]=json.object({visited=true,last_departure_days=slot.last_departure_days or json.null})
   end
   areas[id]=json.object({floor_count=area.floor_count,floors=floors,tile_id=area.tile_id or json.null,
    map_kind=area.config and area.config.map and area.config.map.kind or json.null})
  end
 end
 return json.object({areas=areas,current_area=state._dm_current_area or json.null,
  current_floor=state._dm_current_floor or json.null,outside=not not state._dm_area_outside})
end
return M
