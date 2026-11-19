-- Synthetic world/session. Only the isolated proof driver can invoke this.
local M={}
local area=require 'local_area'
local placement=require 'scene_placement'
local json=require 'json_validate'
local function project(a)
 local items={};for k,inv in pairs(a.inven or {})do if type(k)=='number'then for _,o in ipairs(inv)do items[#items+1]=o.uid end end end;table.sort(items)
 return json.object({uid=a.uid,level=a.level,hp=a.life,items=json.array(items)})
end
function M.run(s,p)
 if p.phase=='setup'then
  area.bind(s,{area_id='area:probe-a',floor_count=1})
  area.enter(s,{area_id='area:probe-a',floor=1,world_clock={world_tick=0,day_in_quarter=0}})
  require('campaign_items').adopt(s,'probe-world','probe-campaign')
  local q=placement.query(s,{source='orc'});local enemy
  for _,e in ipairs(q.enemy_catalog)do if e.enemy_id:find('WARRIOR',1,true)then enemy=e.enemy_id;break end end
  assert(enemy,'orc warrior unavailable')
  local r=placement.apply(s,{operation_id='initial-named',enemy_id=enemy,person_id='probe-person',person_name='Probe Person',reference_level=10,placement='same_room'})
  assert(r.status=='applied',r.reason)
  local a=s._dm_world_person_actors['probe-person'];a.life=a.life-7;s._probe_npc=project(a)
  area.enter(s,{area_id='area:probe-b',floor=1,floor_count=1,world_clock={world_tick=2,day_in_quarter=0},config={map={kind='dungeon',size=64},zone={template='ruins-kor-pul',reference_level=14,floor_count=1}}})
  s.game.paused=true
  return s._probe_npc
 elseif p.phase=='surrender'then
  local a=assert(s._dm_world_person_actors['probe-person']);local before=project(a)
  s.visible[a.uid]=true
  require('dm_transition').apply(s,{operation='surrender',operation_id='named-surrender',target=a.uid})
  assert(s._dm_world_person_index['probe-person'].status=='surrendered','surrender not recorded')
  local r=placement.apply(s,{operation_id='fight-again',person_id='probe-person',placement='same_room'})
  assert(r.status=='applied',r.reason)
  assert(a.uid==before.uid and a.life==before.hp and a.level==before.level,'surrender recovery changed identity')
  return json.object({restored=r,after=project(a)})
 elseif p.phase=='check'then
  local a=assert(s._dm_world_person_actors['probe-person']);local before=s._probe_npc
  assert(a.uid==before.uid and a.level==before.level and a.life==before.hp,'cold restore changed actor')
  local data=project(a);assert(#data.items==#before.items,'cold restore lost equipment')
  for i,id in ipairs(before.items)do assert(data.items[i]==id,'cold restore changed equipment UID')end
  local current=s._dm_world_person_index['probe-person'];local count=0
  for _,region in pairs(s._dm_local_areas)do for _,slot in pairs(region.floors)do if slot.level then for _,e in pairs(slot.level.entities)do if e==a then count=count+1 end end end end end
  assert(count==1,'duplicate or missing named actor')
  return json.object({actor=data,area_id=current.area_id,count=count})
 end
 error('unknown fixture phase')
end
return M
