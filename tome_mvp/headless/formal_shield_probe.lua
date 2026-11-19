dofile('/probe.lua')
local state=require('scene').create(11)
local p,e=state.player,state.enemy
local Object=require 'mod.class.Object'
local function equip(path,name)
 local list=Object:loadList(path)
 for _,prototype in ipairs(list) do if prototype.name==name then
  local item=assert(game.zone:finishEntity(game.level,'object',prototype,-1000))
  item:identify(true)
  assert(p:wearObject(item,true,false),'cannot wear '..name)
  return
 end end
 error('missing '..name)
end
assert(p:learnTalent(p.T_ARMOUR_TRAINING,true,2))
equip('/data/general/objects/axes.lua','iron waraxe')
equip('/data/general/objects/shields.lua','iron shield')
for _,id in ipairs({'T_SHIELD_PUMMEL','T_SHIELD_SLAM','T_ASSAULT','T_SHIELD_WALL','T_LAST_STAND'}) do
 if not p:knowTalent(p[id]) then assert(p:learnTalent(p[id],true,1)) end
end
local actions=require 'native_actions'
local hp=e.life
local ok,why=actions.use(p,'T_SHIELD_PUMMEL',e)
assert(ok,why)
assert(p.talents_cd.T_SHIELD_PUMMEL and p.stamina<100,'native cost or cooldown missing')
print('FORMAL_SHIELD_PUMMEL',hp,e.life,p.stamina,p.talents_cd.T_SHIELD_PUMMEL)
-- A second independent native scene starts at a fresh decision boundary.
state=require('scene').create(12)
p=state.player
assert(p:learnTalent(p.T_ARMOUR_TRAINING,true,2))
equip('/data/general/objects/axes.lua','iron waraxe')
equip('/data/general/objects/shields.lua','iron shield')
assert(p:learnTalent(p.T_SHIELD_WALL,true,1))
local a,b=actions.use(p,'T_SHIELD_WALL')
assert(a,b); assert(p:isTalentActive(p.T_SHIELD_WALL),'shield stance inactive')
print('FORMAL_SHIELD_WALL',p.max_stamina,p.stamina)
for index,id in ipairs({'T_SHIELD_SLAM','T_ASSAULT','T_LAST_STAND'}) do
 state=require('scene').create(12+index); p=state.player; e=state.enemy
 assert(p:learnTalent(p.T_ARMOUR_TRAINING,true,2))
 equip('/data/general/objects/axes.lua','iron waraxe')
 equip('/data/general/objects/shields.lua','iron shield')
 assert(p:learnTalent(p[id],true,1))
 local used,why=actions.use(p,id,id=='T_LAST_STAND' and nil or e)
 assert(used,why)
 if id=='T_LAST_STAND' then assert(p:isTalentActive(p[id])) else assert(p.talents_cd[id] and p.stamina<100) end
 print('FORMAL_SHIELD_SKILL',id,e.life,p.stamina)
end
