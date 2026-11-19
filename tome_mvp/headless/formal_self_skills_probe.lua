dofile('/probe.lua')
local actions=require 'native_actions'
local checks={
 {'T_BLOCK',function(p) return p:hasEffect(p.EFF_BLOCKING) end},
 {'T_DWARF_RESILIENCE',function(p) return p:hasEffect(p.EFF_DWARVEN_RESILIENCE) end},
 {'T_REPULSION',function(p) return p:isTalentCoolingDown(p.T_REPULSION) end},
 {'T_DAUNTING_PRESENCE',function(p) return p:isTalentActive(p.T_DAUNTING_PRESENCE) end},
 {'T_INFUSION:_REGENERATION_1',function(p) return p:hasEffect(p.EFF_REGENERATION) end},
 {'T_INFUSION:_WILD_2',function(p) return p:hasEffect(p.EFF_PAIN_SUPPRESSION) end},
 {'T_INFUSION:_HEALING_3',function(p,old) return p.life>old end},
}
for i,entry in ipairs(checks) do
 local state=require('scene').create(11,'formal')
 local p=state.player
 if entry[1]=='T_BLOCK' then p.talents_cd[p.T_BLOCK]=nil end -- isolated cooldown setup, not battle
 if entry[1]=='T_INFUSION:_HEALING_3' then p.life=p.life-100 end -- isolated probe setup only
 local old=p.life
 local okay,reason=actions.use(p,entry[1])
 assert(okay,entry[1]..':'..tostring(reason))
 assert(entry[2](p,old),'missing native effect '..entry[1])
 print('FORMAL_SELF_SKILL',entry[1],p.life,p.energy.value)
end
