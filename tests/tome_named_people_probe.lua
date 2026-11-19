-- Test-only RPC fixture. It mutates only an isolated synthetic Wasm VM.
local M={}
local placement=require 'scene_placement'
local area=require 'local_area'
local json=require 'json_validate'
local function require_applied(r)assert(r.status=='applied',r.reason or 'spawn rejected');return r end
local function party(state)
 local p={};for _,a in ipairs(require('units').party(state))do if a.x and a.y and not a.dead and state.map(a.x,a.y,state.Map.ACTOR)==a then p[#p+1]={x=a.x,y=a.y}end end;return p
end
local function dist(x,y,a)return math.max(math.abs(x-a.x),math.abs(y-a.y))end
local function check(state,r,kind)
 local q=placement.query(state,{include_tiles=true})
 if q.room_mode=='outdoor_visibility' then
  if kind=='same_room'then assert(dist(r.x,r.y,state.player)<=10,'near distance')else for _,a in ipairs(party(state))do assert(dist(r.x,r.y,a)>10,'far distance')end end
 else if kind=='same_room'then assert(r.room_id==q.player.room_id,'wrong room')else assert(r.room_id~=0 and r.room_id~=q.player.room_id,'not another room')end end
end
local function equal(a,b)
 if type(a)~=type(b)then return false end
 if type(a)~='table'then return a==b end
 for k,v in pairs(a)do if not equal(v,b[k])then return false end end
 for k in pairs(b)do if a[k]==nil then return false end end
 return true
end
local function boundary(state,target,mode,operation)
 local map=state.map;local player=state.player;local reachable={};local q={{player.x,player.y}};local head=1;reachable[player.x+player.y*map.w]=true
 while q[head]do local a=q[head];head=head+1;for dy=-1,1 do for dx=-1,1 do if dx~=0 or dy~=0 then
  local x,y=a[1]+dx,a[2]+dy;local key=x+y*map.w
  if x>=0 and y>=0 and x<map.w and y<map.h and not reachable[key]then local t=map(x,y,state.Map.TERRAIN);if t and not t:check('block_move',x,y,player,false,false)then reachable[key]=true;q[#q+1]={x,y}end end
 end end end end
 local target_pos;local occupied={};local others=party(state)
 for y=0,map.h-1 do for x=0,map.w-1 do
  local t=map(x,y,state.Map.TERRAIN)
  if reachable[x+y*map.w] and t and not t:check('block_move',x,y,player,false,false)and not map(x,y,state.Map.ACTOR)then
   local valid=dist(x,y,player)==target
   if mode=='other_room'then local nearest=999;for _,a in ipairs(others)do nearest=math.min(nearest,dist(x,y,a))end;valid=nearest==target end
   if valid and not target_pos then target_pos={x=x,y=y}else occupied[#occupied+1]={x=x,y=y}end
  end
 end end
 assert(target_pos,'missing boundary candidate '..target..' '..mode..' player='..tostring(player.x)..','..tostring(player.y))
 -- Fixture-only occupancy masks candidate cells. Terrain and actual actors are untouched.
 for _,v in ipairs(occupied)do map(v.x,v.y,state.Map.ACTOR,player)end
 local ok,r=pcall(placement.apply,state,{operation_id=operation,person_id='fixture-person',placement=mode})
 for _,v in ipairs(occupied)do map:remove(v.x,v.y,state.Map.ACTOR)end
 assert(ok,r);require_applied(r);assert(r.x==target_pos.x and r.y==target_pos.y,'boundary tile not selected')
 return r
end
local function actor(state)return assert(state._dm_world_person_actors['fixture-person'])end
local function projection(a)
 local inv={};for slot,v in pairs(a.inven or {})do if type(slot)=='number'and type(v)=='table'then for _,item in ipairs(v)do inv[#inv+1]=item.uid end end end;table.sort(inv)
 local skills={};for k,v in pairs(a.talents or {})do skills[tostring(k)]=v end
 local cd={};for k,v in pairs(a.talents_cd or {})do cd[tostring(k)]=v end
 local effect=a.tmp and a.tmp[a.EFF_REGENERATION]
 return json.object({uid=a.uid,life=a.life,inventory=json.array(inv),talents=json.object(skills),cooldowns=json.object(cd),level=a.level,effect=effect and json.object({duration=effect.dur,power=effect.power}) or json.null})
end
function M.run(state,p)
 local op=p.phase
 if op=='boundary_only'then
  area.bind(state,{area_id='fixture-open',floor_count=1})
  local floor=assert(state.map(state.player.x,state.player.y,state.Map.TERRAIN))
  assert(not floor:check('block_move',state.player.x,state.player.y,state.player,false,false),'fixture floor blocked')
  for y=0,state.map.h-1 do for x=0,state.map.w-1 do state.map(x,y,state.Map.TERRAIN,floor)end end
  state.map._dm_rooms=nil;state.map._dm_map_kind='forest'
  local q=placement.query(state,{source='orc'});local enemy=q.enemy_catalog[1].enemy_id
  require_applied(placement.apply(state,{operation_id='open-first',enemy_id=enemy,person_id='fixture-person',person_name='Fixture Person',placement='same_room'}))
  local near=boundary(state,10,'same_room','open-edge-10');local far=boundary(state,11,'other_room','open-edge-11')
  return json.object({fixture_open_terrain=true,near=near,far=far})
 elseif op=='setup'then
  area.bind(state,{area_id='A',floor_count=1})
  area.enter(state,{area_id='A',floor=1,world_clock={world_tick=0,day_in_quarter=0}})
  local q=placement.query(state,{source='orc'});local enemy
  for _,e in ipairs(q.enemy_catalog)do if e.enemy_id:find('WARRIOR',1,true)then enemy=e.enemy_id;break end end
  enemy=enemy or q.enemy_catalog[1] and q.enemy_catalog[1].enemy_id
  assert(enemy,'no spawn prototype')
  local z=state.game.zone;local base,ref=z.base_level,z._project_reference_level
  local r=require_applied(placement.apply(state,{operation_id='first',enemy_id=enemy,person_id='fixture-person',person_name='Fixture Person',reference_level=p.reference_level or 10,placement='same_room'}));check(state,r,'same_room')
  assert(z.base_level==base and z._project_reference_level==ref,'zone difficulty changed after spawn')
  local b10=boundary(state,10,'same_room','edge-10')
  local a=actor(state);a.life=math.max(1,a.life-7)
  -- Fixture-controlled cooldown: the entry is native actor state and must survive.
  assert(a.EFF_REGENERATION,'missing regeneration effect');a:setEffect(a.EFF_REGENERATION,10,{power=1})
  assert(a.tmp and a.tmp[a.EFF_REGENERATION],'effect fixture not applied')
  local tid=next(a.talents or {});if tid then a.talents_cd=a.talents_cd or {};a.talents_cd[tid]=3 end
  state._probe_saved=projection(a);state.game.paused=true
  return json.object({spawn=r,boundary10=b10,zone_base=base,zone_reference=ref,before=state._probe_saved,turn=state.game.turn})
 elseif op=='after_restore'then
  local a=actor(state);local old=state._probe_saved
  assert(a.uid==old.uid and a.life==old.life,'checkpoint changed UID or HP')
  assert(equal(projection(a),old),'checkpoint changed native state')
  local now=state.game.turn
  local r=require_applied(placement.apply(state,{operation_id='same',person_id='fixture-person',placement='other_room'}));check(state,r,'other_room');assert(actor(state)==a,'same-zone actor replaced')
  assert(state.game.turn==now,'placement advanced turn')
  return json.object({after=projection(a),spawn=r,turn=state.game.turn})
 elseif op=='transfer'then
  local a=actor(state);local before=projection(a);local source=state.game.level
  local config={map={kind='dungeon',size=64},zone={template='ruins-kor-pul',reference_level=20,floor_count=1}}
  local enter_b=area.enter(state,{area_id='B',floor=1,floor_count=1,config=config,world_clock={world_tick=2,day_in_quarter=0}})
  local r=require_applied(placement.apply(state,{operation_id='to-B',person_id='fixture-person',placement='same_room'}));check(state,r,'same_room')
  assert(actor(state)==a and equal(projection(a),before),'transfer changed actor')
  local room_b=r
  local other_b=require_applied(placement.apply(state,{operation_id='B-other',person_id='fixture-person',placement='other_room'}));check(state,other_b,'other_room')
  assert(not source:hasEntity(a),'source still contains actor')
  local enter_a=area.enter(state,{area_id='A',floor=1,floor_count=1,world_clock={world_tick=3,day_in_quarter=0}})
  r=require_applied(placement.apply(state,{operation_id='to-A',person_id='fixture-person',placement='same_room'}));check(state,r,'same_room')
  assert(actor(state)==a and equal(projection(a),before),'return changed actor')
  assert(not state._dm_local_areas.B.floors[1].level:hasEntity(a),'B still contains actor')
  area.enter(state,{area_id='B',floor=1,floor_count=1,world_clock={world_tick=4,day_in_quarter=0}})
  local refreshed=area.enter(state,{area_id='A',floor=1,floor_count=1,world_clock={world_tick=9,day_in_quarter=0},reference_level=20})
  assert(refreshed.refreshed and actor(state)==a and state.game.level:hasEntity(a)==a,'annual refresh lost named actor')
  assert(equal(projection(a),before),'annual refresh changed named actor state')
  a.dead=true
  local rejected=placement.apply(state,{operation_id='dead',person_id='fixture-person',placement='same_room'})
  assert(rejected.status=='rejected'and rejected.reason=='named_actor_dead','dead actor restored')
  return json.object({in_B=room_b,other_B=other_b,returned=r,dead=rejected,clock_B=2,clock_A=3,refresh_B=enter_b.refreshed,refresh_A=enter_a.refreshed,annual_refresh=refreshed.refreshed})
 end
 error('unknown fixture phase')
end
return M
