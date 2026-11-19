-- Public creature sheet. Never return a raw Actor graph or a hidden actor.
local M={}
function M.read(state,uid)
 local json=require 'json_validate'
 local a
 for _,actor in ipairs(state.allies) do if tostring(actor.uid)==tostring(uid) then a=actor end end
 for _,actor in ipairs(state.observed_actors or state.enemies) do
  if tostring(actor.uid)==tostring(uid) and not actor.dead and state.visible[actor.uid] then a=actor end
 end
 if not a then return nil,'not_visible' end
 local stats=json.object({})
 for _,key in ipairs({'str','dex','con','mag','wil','cun'}) do stats[key]=a:getStat(key) end
 local derived=json.object({})
 for _,entry in ipairs({{'physical_power','combatPhysicalpower'},{'spell_power','combatSpellpower'},{'mind_power','combatMindpower'},{'accuracy','combatAttack'},{'defence','combatDefense'},{'armour','combatArmor'},{'physical_save','combatPhysicalResist'},{'spell_save','combatSpellResist'},{'mental_save','combatMentalResist'}}) do
  local ok,value=pcall(function() return a[entry[2]](a) end)
  if ok and type(value)=='number' then derived[entry[1]]=value end
 end
 local talents=json.array()
 for id,rank in pairs(a.talents or {}) do
  local t=a:getTalentFromId(id)
  if t and not t.hide then talents[#talents+1]=json.object({id=id,name=t.name,rank=rank,mode=t.mode or 'activated'}) end
 end
 table.sort(talents,function(x,y) return x.id<y.id end)
 local resistances=json.object({})
 local DamageType=require 'engine.DamageType'
 for id,value in pairs(a.resists or {}) do
  local def=type(id)=='number' and DamageType:get(id)
  if type(value)=='number' then resistances[def and def.name or tostring(id)]=value end
 end
 local equipment=json.array()
 for _,inv in pairs(a.inven or {}) do for _,o in ipairs(inv) do
  if inv.worn then equipment[#equipment+1]=json.object({name=tostring(o:getName{do_color=false}),type=o.type or '',subtype=o.subtype or ''}) end
 end end
 return json.object({id=a.uid,name=a.name,level=a.level,rank=a.rank or 1,hp=a.life,max_hp=a.max_life,
  faction=a.faction,stats=stats,combat=derived,resistances=resistances,talents=talents,equipment=equipment,
  scope='current_shared_visibility',generation=state.generation or json.null,turn=state.game.turn})
end
M.read=require('localization').wrap(M.read)
return M
