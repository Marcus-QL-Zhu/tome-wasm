-- Scene layouts on native terrain and admission checks. RNG is never reseeded here.
local M={}
function M.create(zone,actor,scene_config,floor_number)
 local Map=require 'engine.Map'
 local Level=require 'engine.Level'
 local Rooms=require 'engine.generator.map.Rooms'
 local Astar=require 'engine.Astar'
 local config=scene_config or require 'encounter_config'
 local size=(config and config.map.size) or tonumber(TOME_SCENE_SIZE) or 64
 local kind=(config and config.map.kind) or 'rooms'
 assert(size>=10 and size<=64 and size==math.floor(size),'unsupported formal map size')
 assert(({rooms=true,dungeon=true,forest=true,cave=true,town=true,tavern=true})[kind],'unsupported map kind')
 local max_attempts=size==20 and 30 or 12
 for attempt=1,max_attempts do
  local map=Map.new(size,size)
  local level=Level.new(floor_number or 1,map)
  level.id=zone.short_name.."-"..level.level
  game.level=level
  local ux,uy,spots,vaults_enabled
  if kind=='rooms' or kind=='dungeon' then
   local data={
    ['.']='FLOOR',['#']='WALL',floor='FLOOR',wall='WALL',door='DOOR',up='FLOOR',down='FLOOR',
    rooms={'simple'},nb_rooms=config and config.map.room_count or (size==20 and 4 or 14),lite_room_chance=100,force_last_stair=true,
   }
   vaults_enabled=kind=='dungeon' and config.zone and config.zone.loot_reference_level
      and TOME_VAULT_RULES_READY
   if vaults_enabled then
    local roomer=require 'engine.generator.map.Roomer'
    table.insert(data.rooms,{'lesser_vault',8})
    data.lesser_vaults_list=zone.generator.map.lesser_vaults_list
    local policy=require 'content_policy'
    policy.filter_random_boss_talents()
    local prior=rawget(zone,'makeEntity')
    local make=zone.makeEntity
    zone.makeEntity=function(z,target,entity_kind,...)
     if entity_kind~='actor' then return make(z,target,entity_kind,...) end
     local args={...}
     return policy.draw_actor(level,function()
      local entity=make(z,target,entity_kind,unpack(args))
      if entity then policy.check_actor(entity) end
      return entity
     end)
    end
    local previous_level=resolvers.current_level
    resolvers.current_level=zone.base_level+level.level-1
    local ok,x,y,_,_,room_spots=xpcall(function()return roomer.new(zone,map,level,data):generate(level.level)end,debug.traceback)
    resolvers.current_level=previous_level
    rawset(zone,'makeEntity',prior)
    if not ok then error(x,0) end
    ux,uy,spots=x,y,room_spots
   else
    ux,uy,spots=Rooms.new(zone,map,level,data):generate(1)
   end
  else
   -- Layout changes use native Grid entities. Movement, doors and FOV remain native.
   local function put(x,y,key)map(x,y,Map.TERRAIN,assert(zone.grid_list[key],'missing native grid '..key):clone())end
   local floor=(kind=='forest' or kind=='town') and 'GRASS' or 'FLOOR'
   local wall=kind=='forest' and 'HARDTREE' or 'WALL'
   for x=0,size-1 do for y=0,size-1 do
    put(x,y,(x==0 or y==0 or x==size-1 or y==size-1 or kind=='cave') and wall or floor)
   end end
   ux,uy=2,math.floor(size/2);spots={}
   if kind=='forest' then
    for x=2,size-3 do for y=2,size-3 do
     -- Keep a broad cross and the perimeter walkable; trees still obstruct sight.
     if math.abs(x-math.floor(size/2))>1 and math.abs(y-uy)>1 and rng.percent(19) then put(x,y,'HARDTREE')end
    end end
   elseif kind=='cave' then
    local x,y=ux,uy
    for _=1,size*size do
     for dx=-1,1 do for dy=-1,1 do
      local px,py=x+dx,y+dy
      if px>0 and px<size-1 and py>0 and py<size-1 then put(px,py,'FLOOR')end
     end end
     local d=({{1,0},{0,1},{-1,0},{0,-1}})[rng.range(1,4)]
     x=math.max(2,math.min(size-3,x+d[1]));y=math.max(2,math.min(size-3,y+d[2]))
    end
   elseif kind=='town' then
    for x=4,size-6,9 do for y=2,size-6,9 do
     for dx=0,4 do for dy=0,4 do
      put(x+dx,y+dy,(dx==0 or dx==4 or dy==0 or dy==4) and 'WALL' or 'FLOOR')
     end end
     put(x+2,y+4,'DOOR')
    end end
   elseif kind=='tavern' then
    -- One shared room with a bar, rather than disconnected BSP rooms.
    for x=4,size-3 do put(x,2,'WALL')end
   end
  end
  if ux and uy and not level.force_recreate then
   local function pass(x,y,could)
    local g=map(x,y,Map.TERRAIN)
    return g and not g:check('block_move',x,y,actor,false,could)
   end
   local q={{ux,uy}}; local seen={[ux+uy*size]=true}; local head=1
   while head<=#q do
    local pos=q[head]; head=head+1
    for _,d in ipairs({{1,0},{0,1},{-1,0},{0,-1},{1,1},{1,-1},{-1,1},{-1,-1}}) do
     local x,y=pos[1]+d[1],pos[2]+d[2]
     if x>=0 and x<size and y>=0 and y<size and not seen[x+y*size] and pass(x,y,true) then
      seen[x+y*size]=true; q[#q+1]={x,y}
     end
    end
   end
   local total,wide=0,{}
   for x=0,size-1 do for y=0,size-1 do
    if pass(x,y,true) then total=total+1 end
    if not map.attrs(x,y,'vault_id') and x>0 and x<size-1 and y>0 and y<size-1 and seen[x+y*size] then
     local clear=true
     for dx=-1,1 do for dy=-1,1 do if not seen[x+dx+(y+dy)*size] or map.attrs(x+dx,y+dy,'vault_id') or not pass(x+dx,y+dy,false) then clear=false end end end
     if clear then wide[#wide+1]={x=x,y=y} end
    end
   end end
   local paths=true
   local astar=Astar.new(map,actor)
   for _,spot in ipairs(spots or {}) do
    if not map.attrs(spot.x,spot.y,'vault_id') and not ((spot.x==ux and spot.y==uy) or astar:calc(ux,uy,spot.x,spot.y)) then paths=false; break end
   end
   if #q==total and #wide>=1 and paths and not map.attrs(ux,uy,'vault_id') then
    map._dm_map_kind=kind
    require('scene_placement').rooms({map=map,Map=Map,player=actor})
    local floors={}
    for _,pos in ipairs(q)do
     if not map.attrs(pos[1],pos[2],'vault_id') and pass(pos[1],pos[2],false)then
      floors[#floors+1]={x=pos[1],y=pos[2]}
     end
    end
    if vaults_enabled then
     -- Native room descriptors retain their generator closures, which are not
     -- needed once the layout and per-cell room IDs have been assigned.
     map.room_map.rooms=nil
     map.room_map.rooms_failed=nil
    end
    return {map=map,level=level,entry={x=ux,y=uy},wide=wide,attempts=attempt,reachable=total,spots=spots,floors=floors}
   end
  end
  if level.vaults_list then
   for x=0,size-1 do for y=0,size-1 do
    for _,entry in ipairs(map.room_map[x][y].add_entities or {})do entry[2]:removed() end
   end end
  end
 end
 error(kind..' failed connectivity after '..max_attempts..' attempts')
end

function M.enemy_positions(generated,spawn,count)
 local size=generated.map.w
 local distance=math.max(3,math.min(12,math.floor(size/5)))
 local spacing=math.max(2,math.min(6,math.floor(size/10)))
 local selected={}
 for _,pos in ipairs(generated.wide)do
  local okay=math.max(math.abs(pos.x-spawn.x),math.abs(pos.y-spawn.y))>=distance
  for _,other in ipairs(selected)do
   if math.max(math.abs(pos.x-other.x),math.abs(pos.y-other.y))<spacing then okay=false end
  end
  if okay and count>0 then selected[#selected+1]=pos;if #selected==count then break end end
 end
 if #selected<count then
  -- Enemies do not need the party's three-wide start. Tight rooms can use
  -- ordinary reachable floor cells, but never a closed door or occupied cell.
  for _,pos in ipairs(generated.floors or {})do
   local okay=math.max(math.abs(pos.x-spawn.x),math.abs(pos.y-spawn.y))>=math.max(2,distance-1)
   for _,other in ipairs(selected)do if pos.x==other.x and pos.y==other.y then okay=false end end
   if okay then selected[#selected+1]=pos;if #selected==count then break end end
  end
 end
 assert(#selected==count,'not enough separated native spawn locations')
 return selected
end
return M
