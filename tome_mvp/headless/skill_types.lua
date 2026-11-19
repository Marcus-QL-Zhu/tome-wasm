local M = {}
-- Explicit engineering representatives; names, modes and costs are read from ToME.
M.entries = {
 {id='T_RUSH', target='hostile'},
 {id='T_MANATHRUST', target='hostile'}, {id='T_LIGHTNING', target='hostile'},
 {id='T_FIREFLASH', target='grid'}, {id='T_DEATH_DANCE_ASSAULT', target='self'},
 {id='T_UNSTOPPABLE', target='self'}, {id='T_STUNNING_BLOW_ASSAULT', target='hostile'},
 {id='T_HEALING_LIGHT', target='self'}, {id='T_EVASION', target='self'},
 {id='T_ARCANE_POWER', target='self'},
 -- The Bulwark source build uses the native shield-offense hit geometry and
 -- self-targeted shield stances. These paths still require formal-scene tests.
 {id='T_SHIELD_PUMMEL', target='hostile'}, {id='T_SHIELD_SLAM', target='hostile'},
 {id='T_ASSAULT', target='hostile'}, {id='T_SHIELD_WALL', target='self'}, {id='T_LAST_STAND', target='self'},
 {id='T_BLOCK', target='self'}, {id='T_DWARF_RESILIENCE', target='self'},
 {id='T_REPULSION', target='self'}, {id='T_DAUNTING_PRESENCE', target='self'},
}
for _,name in ipairs({'REGENERATION','HEALING','WILD'}) do
 for slot=1,6 do M.entries[#M.entries+1]={id='T_INFUSION:_'..name..'_'..slot,target='self'} end
end
local groups = {
 {'T_MANATHRUST','T_ARCANE_POWER'}, {'T_LIGHTNING'},
 {'T_FLAME','T_FLAMESHOCK','T_FIREFLASH'},
 {'T_STUNNING_BLOW_ASSAULT','T_FEARLESS_CLEAVE','T_DEATH_DANCE_ASSAULT'},
 {'T_MORTAL_TERROR','T_BLOODBATH','T_BLOODY_BUTCHER','T_UNSTOPPABLE'},
 {'T_HEALING_LIGHT'}, {'T_DISENGAGE','T_EVASION'},
}
function M.install(p)
 p.level=22
 for _,stat in ipairs({'str','dex','mag'}) do
  local n=p:getStat(stat); if n<50 then p:incStat(stat,50-n) end
 end
 -- Resource pools are innate unlocks, rather than normal learnable class talents.
 for _,id in ipairs({'T_MANA_POOL','T_STAMINA_POOL','T_POSITIVE_POOL'}) do
  if not p:knowTalent(p[id]) then assert(p:learnTalent(p[id],true,1),id) end
 end
 if p:getMaxStamina()<200 then p:incMaxStamina(200-p:getMaxStamina()) end
 for _,group in ipairs(groups) do
  for _,id in ipairs(group) do
   local tid=assert(p[id],id); local t=assert(p:getTalentFromId(tid),id)
   if not p:knowTalentType(t.type[1]) then p:learnTalentType(t.type[1],true) end
   if not p:knowTalent(tid) then
    local ok,why=p:canLearnTalent(t); assert(ok,id..': '..tostring(why))
    assert(p:learnTalent(tid,false,1),id)
   end
  end
 end
 local Object=require 'mod.class.Object'
 local old=game.zone.object_list
 local list=Object:loadList('/data/general/objects/2hswords.lua')
 local sword
 for _,prototype in ipairs(list) do if prototype.name=='iron greatsword' then sword=game.zone:finishEntity(game.level,'object',prototype,-1000); break end end
 assert(sword,'missing iron greatsword'); sword:identify(true)
 assert(p:wearObject(sword,true,false) and p:getInven('MAINHAND')[1]==sword,'cannot equip greatsword')
 game.zone.object_list=old
end
return M


