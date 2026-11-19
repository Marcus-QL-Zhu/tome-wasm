-- Private diagnostic projection. This is not a complete replay certificate.
local json=require 'json_validate'
local M={}
-- One-time binding, only called at the worker's initial formal boundary.
function M.bind(state, members)
 assert(type(members)=='table' and #members==3, 'three members required')
 local seen={}
 local item_seen={}
 local assignments={}
 for i,m in ipairs(members) do
  local a=state.allies[i]
  assert(type(m)=='table' and type(m.id)=='string' and #m.id>0 and #m.id<=128 and not seen[m.id], 'invalid identity')
  assert(type(m.name)=='string' and #m.name>0 and #m.name<=128, 'invalid name')
  assert(m.hp==json.null or (type(m.hp)=='number' and m.hp==m.hp and m.hp>=1 and m.hp<=a.max_life), 'invalid hp')
  seen[m.id]=true
  assert(m.items==nil or type(m.items)=='table','invalid item bindings')
  for _,binding in ipairs(m.items or {}) do
   assert(type(binding.relic_id)=='string' and #binding.relic_id>0 and #binding.relic_id<=128 and not item_seen[binding.relic_id], 'invalid relic id')
   assert(type(binding.slot)=='string' and type(binding.pos)=='number' and binding.pos==math.floor(binding.pos) and binding.pos>=1, 'invalid item position')
   assert(type(binding.name)=='string' and binding.cha==nil, 'invalid item properties')
   local slot=a['INVEN_'..binding.slot]; local inv=slot and a:getInven(slot); local item=inv and inv[binding.pos]
   assert(item and item.name==binding.name and not assignments[item], 'item identity mismatch')
   item_seen[binding.relic_id]=true; assignments[item]=binding
  end
 end
 for item,binding in pairs(assignments) do item._dm_relic_id=binding.relic_id end
 for i,m in ipairs(members) do
  local a=state.allies[i]
  a._dm_world_id=m.id; a.name=m.name; a.life=(m.hp==json.null) and a.max_life or m.hp
 end
 return M.inspect(state)
end
function M.inspect(state)
 local rs=rng.state_get(); rs.words=json.array(rs.words)
 local party,reserves=json.array(),json.array()
 for _,a in ipairs(require('company_roster').members(state)) do
  local equipment=json.array(); local cha=0; local gear_score=0; local charisma=require('dm_charisma')
  for id,inv in pairs(a.inven or {})do
   if a.inven_def[id] and a.inven_def[id].is_worn then
    for _,item in ipairs(inv)do gear_score=gear_score+(item.material_level or 0)end
   end
  end
  local descriptor=json.object({});local skills=json.array()
  local effects=json.array()
  for id in pairs(a.sustain_talents or {}) do
   local talent=a:getTalentFromId(id)
   if talent and a:isTalentActive(id) then effects[#effects+1]=tostring(talent.name) end
  end
  for id in pairs(a.tmp or {})do
   local def=a.tempeffect_def[id]
   if def and def.decrease==0 and def.desc then effects[#effects+1]=tostring(def.desc) end
  end
  table.sort(effects)
  for _,key in ipairs({'race','subrace','class','subclass','sex'}) do
   if type((a.descriptor or {})[key])=='string' then descriptor[key]=a.descriptor[key] end
  end
  for tid,rank in pairs(a.talents or {}) do
   if type(rank)=='number' and rank>0 then local t=a:getTalentFromId(tid)
    if t then skills[#skills+1]=json.object({name=tostring(t.name),level=rank,mode=t.mode or 'activated',category=t.type and t.type[1] or 'other',category_name=require('localization').category(t.type and t.type[1] or 'other'),_tid=tostring(tid)}) end
   end
  end
  table.sort(skills,function(x,y) if x.name~=y.name then return x.name<y.name end return x._tid<y._tid end)
  for _,skill in ipairs(skills) do skill._tid=nil end
  for _,slot in ipairs(a.inven_def or {}) do
   if slot.short_name~='INVEN' then
    for _,item in ipairs(a:getInven(slot.id) or {}) do
     cha=cha+charisma.bonus(item)
     equipment[#equipment+1]=json.object({slot=slot.short_name,uid=item.uid,name=item.name or '',relic_id=item._dm_relic_id or json.null,cha=charisma.bonus(item),cha_affix=item._dm_cha_affix and json.object(item._dm_cha_affix) or json.null})
    end
   end
  end
  local occupants=state.game.party:hasMember(a) and party or reserves
  occupants[#occupants+1]=json.object({uid=a.uid,world_id=a._dm_world_id or json.null,origin=a._dm_origin or json.null,name=a.name,level=a.level,hp=a.life,max_hp=a.max_life,down=require('rescue').is_down(a) and true or false,cha_equipment=cha,
   stats=json.object({str=a:getStr(),dex=a:getDex(),mag=a:getMag(),wil=a:getWil(),cun=a:getCun(),con=a:getCon()}),equipment=equipment,gear_score=gear_score,
   equipment_slots=require('campaign_loadout').slots(a),inventory=require('campaign_loadout').inventory(a),active_weapon_set=a._dm_active_weapon_set or 'main',
   descriptor=descriptor,skills=skills,effects=effects,preparation=require('campaign_loadout').preparation(a,state),progression=require('dm_progression').snapshot(a)})
 end
 local next_uid
 local init=require('engine.Entity').init
 for index=1,debug.getinfo(init,'u').nups do
  local name,value=debug.getupvalue(init,index)
  if name=='next_uid' then next_uid=value end
 end
 assert(type(next_uid)=='number','missing UID allocator')
 local actors=json.array()
 for _,group in ipairs({state.allies,state.enemies}) do
  for _,a in ipairs(group) do
   local items=json.array()
   for slot,inv in pairs(a.inven or {}) do
    if type(slot)=='number' and type(inv)=='table' then
     for pos,item in ipairs(inv) do
      items[#items+1]=json.object({slot=slot,pos=pos,uid=item.uid or json.null,name=item.name or json.null,
       relic_id=item._dm_relic_id or json.null,cha=require('dm_charisma').bonus(item)})
     end
    end
   end
   table.sort(items,function(x,y) return x.slot==y.slot and x.pos<y.pos or x.slot<y.slot end)
   local cds=json.object()
   for k,v in pairs(a.talents_cd or {}) do if type(v)=='number' then cds[tostring(k)]=v end end
   actors[#actors+1]=json.object({uid=a.uid,name=a.name,x=a.x,y=a.y,hp=a.life,max_hp=a.max_life,
    energy=a.energy and a.energy.value or json.null,dead=a.dead and true or false,items=items,cooldowns=cds})
  end
 end
 local terrain=json.array()
 if state.map then for y=0,state.map.h-1 do for x=0,state.map.w-1 do
  local g=state.map(x,y,state.Map.TERRAIN)
  terrain[#terrain+1]=g and json.array({g.uid or json.null,g.define_as or json.null,g.name or json.null}) or json.null
 end end end
 local enemies=json.array()
 for _,a in ipairs(state.enemies) do enemies[#enemies+1]=json.object({uid=a.uid,hp=a.life,x=a.x,y=a.y,dead=a.dead and true or false}) end
 local ground=json.object()
 for id,e in pairs(state._dm_ground_items or {})do
  local area_id,floor=e.area_id,e.floor
  if e.map then
   for aid,area in pairs(state._dm_local_areas or {})do for n,slot in pairs(area.floors or {})do
    if slot.level and slot.level.map==e.map then assert(not area_id,'ground map belongs to multiple floors');area_id=aid;floor=n end
   end end
   assert(e.item and require('campaign_items').on_ground(e.map,e.x,e.y,e.item,e.attached),'ground object missing')
  end
  local location_only=not e.offline and not e.map
  if location_only then
   local holder=state._dm_item_holders and state._dm_item_holders[id]
   assert(e.item and state._dm_item_objects and state._dm_item_objects[id]==e.item and type(e.location)=='string' and #e.location>0 and holder and holder.kind=='world_location' and holder.id==e.location,'invalid location-only ground item')
  end
  ground[id]=json.object({uid=e.uid or (e.item and e.item.uid),ref=e.ref,location=e.location,area_id=area_id,floor=floor,x=e.x,y=e.y,location_only=location_only})
 end
 local victor=require('campaign_wipeout').victor(state)
 local defeat_victor=victor and json.object({uid=victor.uid,name=victor.name,person_id=victor._dm_histfig_id,
  type=victor.type,subtype=victor.subtype})
 return json.object({defeat_victor=defeat_victor,coverage='bounded',rng=json.object(rs),next_uid=next_uid,turn=state.game.turn,control=state.player.uid,terrain=terrain,actors=actors,party=party,reserves=reserves,enemies=enemies,ground_items=ground})
end
M.inspect=require('localization').wrap(M.inspect)
return M
