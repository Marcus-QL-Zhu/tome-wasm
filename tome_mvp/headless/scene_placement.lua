-- Host-only single-actor placement. No turns, facing, or combat-AI overrides.
local M={}
local json=require 'json_validate'
local function pass(state,x,y)
 local g=state.map(x,y,state.Map.TERRAIN)
 return g and not g:check('block_move',x,y,state.player,false,false)
end
function M.rooms(state)
 local map=state.map
 if map._dm_rooms then return map._dm_rooms end
 local labels,rooms={},{}
 local native=false
 for y=0,map.h-1 do for x=0,map.w-1 do
  local cell=map.room_map and map.room_map[x] and map.room_map[x][y]
  local id=cell and cell.room
  local key=(type(id)=='number' or type(id)=='string') and tostring(id)or nil
  labels[x+y*map.w+1]=0
  if key and pass(state,x,y)then
   if not rooms[key]then rooms[key]=#rooms+1;rooms[#rooms+1]={id=#rooms+1,source='native',native_id=key}end
   labels[x+y*map.w+1]=rooms[key];native=true
  end
 end end
 local has_doors=false
 for y=0,map.h-1 do for x=0,map.w-1 do local g=map(x,y,state.Map.TERRAIN);if g and (g.door_opened or g.door_closed)then has_doors=true end end end
 if not native and (map._dm_map_kind=='forest' or not has_doors) then
  map._dm_rooms={mode='outdoor_visibility',labels=labels,rooms={}}
  return map._dm_rooms
 end
 -- Rooms (BSP) only emits spots. Fill missing interiors/corridors by flood
 -- fill, keeping native Roomer IDs and treating open and closed doors alike.
 for y=0,map.h-1 do for x=0,map.w-1 do
  local index=x+y*map.w+1;local g=map(x,y,state.Map.TERRAIN)
  if labels[index]==0 and pass(state,x,y)and not g.door_opened and not g.door_closed then
   local id=#rooms+1;rooms[id]={id=id,source='door_component'}
   local queue={{x,y}};labels[index]=id;local head=1
   while queue[head]do
    local p=queue[head];head=head+1
    for _,d in ipairs({{1,0},{-1,0},{0,1},{0,-1}})do
     local nx,ny=p[1]+d[1],p[2]+d[2]
     if nx>=0 and ny>=0 and nx<map.w and ny<map.h then
      local k=nx+ny*map.w+1;local t=map(nx,ny,state.Map.TERRAIN)
      if labels[k]==0 and pass(state,nx,ny)and not t.door_opened and not t.door_closed then
       labels[k]=id;queue[#queue+1]={nx,ny}
      end
     end
    end
   end
  end
 end end
 local clean={};for i,r in ipairs(rooms)do clean[i]=r end
 map._dm_rooms={mode=native and 'native_with_corridors'or'door_components',labels=labels,rooms=clean}
 return map._dm_rooms
end
local function source_id(id)
 if type(id)~='string'or #id>200 then return end
 local source,key=id:match('^([a-z0-9_-]+):(.+)$')
 if source and #source<=64 and #key<=128 and not key:find('[%c]')then return source,key end
end
local function list(source)
 assert(type(source)=='string' and source:match('^[a-z0-9_-]+$')and #source<=64,'invalid NPC source')
 assert(fs.exists('/data/general/npcs/'..source..'.lua'),'unknown NPC source')
 return require('mod.class.NPC'):loadList('/data/general/npcs/'..source..'.lua')
end
function M.people(state)
 local people={}
 for id,entry in pairs(state._dm_world_person_index or {})do
  local actor=state._dm_world_person_actors and state._dm_world_person_actors[id]
  if actor and actor.dead then entry.status='dead' end
  people[id]=json.object({actor_uid=entry.actor_uid,area_id=entry.area_id,floor=entry.floor,status=entry.status,level=actor and actor.level or entry.level,enemy_id=entry.enemy_id,
   wipeout_victor=entry.wipeout_victor,subclass=actor and actor.descriptor and actor.descriptor.subclass})
 end
 return json.object(people)
end
function M.query(state,request)
 request=request or {};local result
 if not request.catalog_only then
 local map=state.map;local index=M.rooms(state)
 local rooms=json.array();for _,r in ipairs(index.rooms)do
  local row={id=r.id,source=r.source,count=0}
  for y=0,map.h-1 do for x=0,map.w-1 do if index.labels[x+y*map.w+1]==r.id then
   row.count=row.count+1;row.x1=math.min(row.x1 or x,x);row.y1=math.min(row.y1 or y,y)
   row.x2=math.max(row.x2 or x,x);row.y2=math.max(row.y2 or y,y)
  end end end
  rooms[#rooms+1]=json.object(row)
 end
 result={width=map.w,height=map.h,room_mode=index.mode,rooms=rooms,
  player=json.object({x=state.player.x,y=state.player.y,room_id=index.labels[state.player.x+state.player.y*map.w+1]}),
  coordinate_origin='zero_based_top_left',same_room=index.mode=='outdoor_visibility'and'controlled_actor_distance_at_most_10'or'room_id',
  other_room=index.mode=='outdoor_visibility'and'distance_over_10_from_all_party'or'different_room_id'}
 result.world_people=M.people(state)
 if request.include_tiles then
  local positions=json.array();for _,a in ipairs(require('units').party(state))do if a.x and a.y and not a.dead and map(a.x,a.y,state.Map.ACTOR)==a then positions[#positions+1]=json.object({x=a.x,y=a.y})end end
  result.party_positions=positions
  local rows,visibility=json.array(),json.array()
  for y=0,map.h-1 do local row,seen='','';for x=0,map.w-1 do
   row=row..(map(x,y,state.Map.ACTOR)and'@'or(pass(state,x,y)and'.'or'#'))
   seen=seen..(map.seens(x,y)and'p'or(state.shared_seen and state.shared_seen[x+y*map.w]and's'or'.'))
  end;rows[#rows+1]=row;visibility[#visibility+1]=seen end
  result.tiles=rows;result.legend='.=walkable #=blocked @=occupied; x increases right, y increases down'
  result.room_labels=json.array(index.labels)
  result.visibility=visibility;result.visibility_legend='p=controlled actor sight, s=other squad sight, .=not currently visible; actor stealth/perception remains native'
 end
 end
 result=result or {};result.world_people=M.people(state)
 if request.source then
  local catalogue=json.array()
  for key,e in pairs(list(request.source))do
   if type(key)=='string'and not key:match('^BASE_')and e.name then
    catalogue[#catalogue+1]=json.object({enemy_id=request.source..':'..key,name=e.name,rank=e.rank or 2})
   end
  end
  table.sort(catalogue,function(a,b)return a.enemy_id<b.enemy_id end);result.enemy_catalog=catalogue
 else
  local sources=json.array();for _,f in ipairs(fs.list('/data/general/npcs'))do if f:match('%.lua$')then sources[#sources+1]=f:sub(1,-5)end end
  table.sort(sources);result.enemy_sources=sources
 end
 return json.object(result)
end
function M.apply(state,op)
 local function reject(reason)return json.object({status='rejected',reason=reason})end
 local existing=op.person_id and state._dm_world_person_index and state._dm_world_person_index[op.person_id]
 if existing and existing.enemy_id and op.enemy_id and op.enemy_id~=existing.enemy_id then return reject('named_actor_enemy_id_conflict')end
 local enemy_id=(existing and existing.enemy_id) or (not op.person_birth and op.enemy_id)
 local source,key=source_id(enemy_id)
 if not source and not existing and not op.person_birth then return reject('invalid_enemy_id')end
 if op.placement~='exact'and op.placement~='same_room'and op.placement~='other_room'then return reject('invalid_placement')end
 local map=state.map;local index=M.rooms(state);local player=state.player
 local signature=tostring(op.enemy_id)..'|'..op.placement..'|'..tostring(op.x)..'|'..tostring(op.y)..'|'..tostring(op.person_id)..'|'..tostring(op.person_name)..'|'..tostring(op.reference_level)..(op.person_birth and '|'..json.encode(json.object(op.person_birth)) or '')
 local receipts=state.game.level._dm_spawns or {}
 if receipts[op.operation_id]then
  if receipts[op.operation_id].signature~=signature then return reject('operation_id_conflict')end
  return receipts[op.operation_id].result
 end
 local person=existing
 local was_bound=not not person
 local actor=person and state._dm_world_person_actors and state._dm_world_person_actors[op.person_id]
 if person then
  if not actor or actor.uid~=person.actor_uid then return reject('named_actor_missing')end
  if actor.dead then person.status='dead' end
  if person.status~='alive'and person.status~='surrendered' and person.status~='released' then return reject('named_actor_'..tostring(person.status))end
  if op.reference_level~=nil then return reject('existing_actor_reference_level')end
  local area=state._dm_local_areas and state._dm_local_areas[person.area_id]
  local slot=area and area.floors[person.floor]
  if person.status~='released' and (not slot or not slot.level) then return reject('named_source_not_resident')end
  local found=false;for _,e in pairs(slot and slot.level.entities or {})do if e==actor then found=true;break end end
  if person.status=='surrendered'then
   local retired=false;for _,e in ipairs(state.retired_enemies or {})do if e==actor then retired=true end end
   if found or not retired then return reject('named_surrendered_actor_missing')end
  elseif person.status~='released' and (not found or not actor.x or not actor.y or slot.level.map(actor.x,actor.y,state.Map.ACTOR)~=actor) then return reject('named_actor_not_in_source')end
 end
 local restore_zone
 local x,y=op.x,op.y
 local function free(px,py)return pass(state,px,py)and not map(px,py,state.Map.ACTOR)end
 if op.placement=='exact'then
  if type(x)~='number'or type(y)~='number'or x~=math.floor(x)or y~=math.floor(y)or x<0 or y<0 or x>=map.w or y>=map.h then return reject('coordinate_out_of_bounds')end
  if not free(x,y)then return reject('coordinate_blocked_or_occupied')end
 else
  local candidates={};local anchor=index.labels[player.x+player.y*map.w+1]
  if index.mode~='outdoor_visibility'and anchor==0 then return reject('player_not_in_room')end
  local reachable={};local queue={{player.x,player.y}};reachable[player.x+player.y*map.w]=true;local head=1
  while queue[head]do local p=queue[head];head=head+1
   for dy=-1,1 do for dx=-1,1 do if dx~=0 or dy~=0 then
    local nx,ny=p[1]+dx,p[2]+dy;local k=nx+ny*map.w
    local grid=map:isBound(nx,ny) and map(nx,ny,state.Map.TERRAIN)
    if grid and not reachable[k] and (pass(state,nx,ny) or (not grid.door_player_check and (grid.door_opened or grid.door_closed)))then
     reachable[k]=true;queue[#queue+1]={nx,ny}
    end
   end end end
  end
  local party=require('units').party(state)
  for py=0,map.h-1 do for px=0,map.w-1 do if free(px,py) and reachable[px+py*map.w]then
   local here,other
   if index.mode=='outdoor_visibility'then
    here=math.max(math.abs(px-player.x),math.abs(py-player.y))<=10;other=true
    for _,a in ipairs(party)do if a.x and a.y and not a.dead and map(a.x,a.y,state.Map.ACTOR)==a and math.max(math.abs(px-a.x),math.abs(py-a.y))<=10 then other=false;break end end
   else
    local label=index.labels[px+py*map.w+1];here=label==anchor;other=label>0 and label~=anchor
   end
   if (op.placement=='same_room'and here)or(op.placement=='other_room'and other)then candidates[#candidates+1]={px,py}end
  end end end
  if #candidates==0 then return reject('no_legal_placement')end
  local pos=rng.table(candidates);x,y=pos[1],pos[2]
 end
 if not actor then
  if op.person_birth then
   local birth=op.person_birth
   local roster=require 'formal_roster'
   actor=roster.create_auto({id=op.person_id,name=op.person_name,level=math.min(50,op.reference_level),
    source_mode='native',stats={},talents={},race=birth.race,subrace=birth.subrace,class=birth.class,
    subclass=birth.subclass,sex=birth.sex})
   roster.equip_auto(actor)
  else
  local ok,prototypes=pcall(list,source)
  local prototype=ok and prototypes[key]
  if not prototype or type(key)~='string'or key:match('^BASE_')or not prototype.name then return reject('unknown_enemy_id')end
  if op.person_id and (type(op.person_id)~='string' or type(op.person_name)~='string')then return reject('invalid_person_identity')end
  if op.reference_level~=nil and (type(op.reference_level)~='number' or op.reference_level~=math.floor(op.reference_level) or op.reference_level<1 or op.reference_level>150)then return reject('invalid_reference_level')end
  for name,entity in pairs(prototypes)do if type(name)=='string'and not game.zone.npc_list[name]then game.zone.npc_list[name]=entity end end
  if op.reference_level then
   local z=game.zone;local old={range=z.level_range,base=z.base_level,base_range=z.base_level_range,applied=z.__applied_difficulty}
   restore_zone=function()z.level_range=old.range;z.base_level=old.base;z.base_level_range=old.base_range;z.__applied_difficulty=old.applied end
   game:applyDifficulty(z,op.reference_level)
  end
  local ok_create,created=pcall(game.zone.finishEntity,game.zone,game.level,'actor',prototype)
  if not ok_create then if restore_zone then restore_zone()end;error(created)end
  actor=assert(created,'native NPC creation failed')
  end
  require('content_policy').check_actor(actor)
  actor.native_source_faction=actor.faction;actor.faction='enemies';actor._dm_named=true
  if op.person_id then
   actor._dm_histfig_id=op.person_id;actor.name=op.person_name
   state._dm_world_person_index=state._dm_world_person_index or {};state._dm_world_person_actors=state._dm_world_person_actors or {}
   person={actor_uid=actor.uid,area_id=state._dm_current_area,floor=state._dm_current_floor,status='alive',level=actor.level,enemy_id=enemy_id}
   state._dm_world_person_index[op.person_id]=person;state._dm_world_person_actors[op.person_id]=actor
  end
 else
  local slot=person.area_id and state._dm_local_areas[person.area_id].floors[person.floor]
  if slot and slot.level:hasEntity(actor)then slot.level:removeEntity(actor,true)end
  for i=#(state.retired_enemies or {}),1,-1 do if state.retired_enemies[i]==actor then table.remove(state.retired_enemies,i)end end
  if person.status=='released' then
   require('formal_roster').ensure_basic_equipment(actor)
   actor.faction='enemies';actor.ai='improved_tactical';actor.ai_state={}
  end
  person.status='alive'
  for i=#(slot and slot.enemies or {}),1,-1 do if slot.enemies[i]==actor then table.remove(slot.enemies,i)end end
  if state.game:hasEntity(actor)then state.game:removeEntity(actor)end
  person.area_id=state._dm_current_area;person.floor=state._dm_current_floor
 end
 local added,err=pcall(game.zone.addEntity,game.zone,game.level,actor,'actor',x,y)
 if restore_zone then restore_zone()end
 if not added then error(err)end
 require('content_policy').check_actor(actor);actor:updateModdableTile()
 for i=#state.enemies,1,-1 do if state.enemies[i]==actor then table.remove(state.enemies,i)end end
 state.enemies[#state.enemies+1]=actor
 local result=json.object({status='applied',operation_id=op.operation_id,enemy_id=enemy_id,
  actor_id=actor.uid,name=actor.name,x=x,y=y,room_mode=index.mode,room_id=index.labels[x+y*map.w+1],
  placement=op.placement,level=actor.level,person_id=op.person_id,restored=was_bound})
 receipts[op.operation_id]={signature=signature,result=result};state.game.level._dm_spawns=receipts
 return result
end
return M
