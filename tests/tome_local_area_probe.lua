local area=require 'local_area'
require('dm_progression').install()
local p=s.player
local first=s.game.level
local firstmap=first.map
local xp=p.exp
local hp=p.life
local uid=p.uid
local original_item=p:getInven('MAINHAND')[1]
local before_count=0
for _,e in pairs(first.entities)do if e._dm_normal_population then before_count=before_count+1 end end
assert(before_count>0,'no marked native population')
area.bind(s,{area_id='forest-a',floor_count=1})
local config={map={kind='dungeon',size=64},zone={template='ruins-kor-pul',reference_level=20,floor_count=2}}
local a=area.transition(s,{area_id='dungeon-b',floor=1,config=config})
assert(a.created and s.game.level~=first and s.player.uid==uid)
local dungeon_one=s.game.level
local dx,dy=1,1
local door=assert(s.game.zone.grid_list.DOOR):clone()
s.map(dx,dy,s.Map.TERRAIN,door)
s.map.remembers(dx,dy,true)
local b=area.transition(s,{area_id='dungeon-b',floor=2})
assert(b.created and s.game.level~=dungeon_one and s.game.level.level==2)
local dungeon_two=s.game.level
area.transition(s,{area_id='dungeon-b',floor=1})
assert(s.game.level==dungeon_one,'floor 1 reconstructed')
assert(s.map(dx,dy,s.Map.TERRAIN)==door and s.map.remembers(dx,dy),'door or explored state lost')
area.transition(s,{area_id='dungeon-b',floor=2})
assert(s.game.level==dungeon_two,'floor 2 reconstructed')
area.transition(s,{area_id='forest-a',floor=1})
assert(s.game.level==first and s.map==firstmap,'forest reconstructed')
assert(p.uid==uid and p.life==hp and p.exp==xp and p:getInven('MAINHAND')[1]==original_item,'party state changed')
local protected_actor
local prior={}
for _,e in pairs(first.entities)do if e._dm_normal_population then prior[e]=true;protected_actor=protected_actor or e end end
protected_actor._dm_histfig_id='histfig-probe'
local x,y=p.x,p.y
local terrain=firstmap(x,y,s.Map.TERRAIN)
local loot=require('mod.class.Object').new{name='probe ground loot',type='armor',subtype='cloak',encumber=1}
firstmap:addObject(x,y,loot)
firstmap.attrs(x,y,'area_probe_memory','retained')
p._dm_world_id='xp-probe'
p:gainExp(100)
assert(p.exp==xp,'unauthorized XP awarded before refresh')
local refreshed=area.refresh_active(s,{reference_level=21})
assert(refreshed.removed>0 and first:hasEntity(protected_actor)==protected_actor,'named actor lost')
for e in pairs(prior)do if e~=protected_actor then assert(not first:hasEntity(e),'ordinary population stacked') end end
assert(first.map==firstmap and firstmap(x,y,s.Map.TERRAIN)==terrain,'terrain replaced')
assert(firstmap:findObject(x,y,loot) and firstmap.attrs(x,y,'area_probe_memory')=='retained','loot or exploration lost')
p:gainExp(100)
assert(p.exp==xp,'unauthorized XP awarded after refresh')
local function clock(days) return {world_tick=math.floor(days/90),day_in_quarter=days%90} end
s._dm_local_areas['dungeon-b'].floors[2].last_departure_days=0
local r=area.enter(s,{area_id='dungeon-b',floor=1,floor_count=2,world_clock=clock(0)})
assert(not r.refreshed)
r=area.enter(s,{area_id='forest-a',floor=1,floor_count=1,world_clock=clock(360)})
assert(not r.refreshed,'exactly one year must not refresh')
r=area.enter(s,{area_id='dungeon-b',floor=1,floor_count=2,world_clock=clock(360),reference_level=21})
assert(not r.refreshed,'same interval must not refresh')
r=area.enter(s,{area_id='forest-a',floor=1,floor_count=1,world_clock=clock(720.5),reference_level=21})
assert(r.refreshed,'strictly more than a year must refresh')
r=area.enter(s,{area_id='forest-a',floor=1,floor_count=1,world_clock=clock(721),reference_level=21})
assert(r.unchanged and not r.refreshed,'same-floor entry refreshed')
r=area.enter(s,{area_id='dungeon-b',floor=1,floor_count=2,world_clock=clock(1081),reference_level=21})
assert(r.refreshed,'dungeon first floor not refreshed')
r=area.enter(s,{area_id='dungeon-b',floor=2,floor_count=2,world_clock=clock(1081),reference_level=21})
assert(r.refreshed,'dungeon second floor not lazily refreshed')
r=area.enter(s,{area_id='dungeon-b',floor=1,floor_count=2,world_clock=clock(1081),reference_level=21})
assert(not r.refreshed,'floor refreshed twice')
r=area.enter(s,{area_id='dungeon-b',floor=2,floor_count=2,world_clock=clock(1441.5),reference_level=21})
assert(r.refreshed,'same area floor revisit after one year did not refresh')
area.depart(s,{world_clock=clock(1442)})
area.depart(s,{world_clock=clock(1450)})
assert(s._dm_local_areas['dungeon-b'].floors[2].last_departure_days==1442,'duplicate depart changed departure time')
r=area.enter(s,{area_id='dungeon-b',floor=2,floor_count=2,world_clock=clock(1802),reference_level=21})
assert(not r.refreshed and not s._dm_area_outside,'same floor at 360 days refreshed or stayed outside')
area.depart(s,{world_clock=clock(1802)})
r=area.enter(s,{area_id='dungeon-b',floor=2,floor_count=2,world_clock=clock(2162.5),reference_level=21})
assert(r.refreshed and not s._dm_area_outside,'same floor after 360.5 days did not refresh')
local victim
for _,e in ipairs(s.enemies)do if not e.dead and e.rank and e.rank<=2 and not e.summoner then victim=e;break end end
assert(victim,'missing ordinary victim')
assert(victim:worthExp(p)>0,'victim has no native experience')
victim:takeHit(victim.life+10000,p)
assert(victim.dead,'native damage did not kill victim')
assert(p.exp==xp,'native kill awarded blocked experience')
print('LOCAL_AREA_PROBE_OK',before_count)
