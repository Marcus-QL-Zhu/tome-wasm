dofile('/probe.lua')
local s=require('scene').create(7)
local p,e,map=s.player,s.enemy,s.map
local a=require('native_actions')
e.max_life=10000; e.life=10000
require('skill_types').install(p); p:resetToFull()
local first_rng=rng.state_get(); local initial_turn=s.game.turn; a.menu(p); local next_rng=rng.state_get()
assert(first_rng.index==next_rng.index and first_rng.stored==next_rng.stored and first_rng.normal_spare==next_rng.normal_spare and s.game.turn==initial_turn)
for i=1,624 do assert(first_rng.words[i]==next_rng.words[i], 'first menu consumed RNG') end
print('SKILL_PASS','first_observe_rng')
local native_use=a.use
a.use=function(actor,id,target)
 local bmana,bstamina,bpositive,benergy=actor:getMana(),actor:getStamina(),actor:getPositive(),actor.energy.value
 local ok,why=native_use(actor,id,target)
 local t=actor:getTalentFromId(actor[id]); local cd=t and actor:isTalentCoolingDown(t) or false
 print('NATIVE_COST',id,tostring(ok),bmana,actor:getMana(),bstamina,actor:getStamina(),bpositive,actor:getPositive(),benergy,actor.energy.value,tostring(cd))
 return ok,why
end
local function ready() p.energy.value=1000 end
local function out(id,detail) print('SKILL_PASS',id,detail or '') end
local hp=p.life; p.life=hp-30; p.positive=0; ready()
assert(a.use(p,'T_HEALING_LIGHT')); assert(p.life>hp-30 and p.life<=p.max_life and p:getPositive()>0); out('healing',p.life)
ready(); local energy=p.energy.value; assert(a.use(p,'T_EVASION')); assert(p:hasEffect(p.EFF_EVASION) and p.energy.value==energy); out('evasion')
ready(); local mana=p:getMaxMana(); assert(a.use(p,'T_ARCANE_POWER')); assert(p:isTalentActive(p.T_ARCANE_POWER) and p:getMaxMana()<mana); out('sustain_on')
e:move(7,4,true); map.clean_fov=true; p:doFOV(); ready(); local cost=p:getMana(); assert(a.use(p,'T_MANATHRUST',e)); assert(p:getMana()<cost)
local proj; for _,v in ipairs(s.game.level.e_array) do if v.__CLASSNAME=='mod.class.Projectile' then proj=v end end
assert(proj,'missing projectile'); local life=e.life; local tick=0
repeat if s.game.paused and p:enoughEnergy() then p:waitTurn() end; s.game:tick(); tick=tick+1 until not s.game.level:hasEntity(proj) or tick>=120
assert(not s.game.level:hasEntity(proj) and e.life<life); out('bolt',tick)
ready(); life=e.life; assert(a.use(p,'T_LIGHTNING',e)); assert(e.life<life); out('beam')
ready(); assert(a.use(p,'T_FIREFLASH',e)); proj=nil; for _,v in ipairs(s.game.level.e_array) do if v.__CLASSNAME=='mod.class.Projectile' then proj=v end end; assert(proj); life=e.life; tick=0
repeat if s.game.paused and p:enoughEnergy() then p:waitTurn() end; s.game:tick(); tick=tick+1 until not s.game.level:hasEntity(proj) or tick>=120
assert(not s.game.level:hasEntity(proj) and e.life<life); out('ranged_aoe',tick)

e:move(5,4,true); map.clean_fov=true; p:doFOV(); p:resetToFull(); ready(); life=e.life
assert(a.use(p,'T_STUNNING_BLOW_ASSAULT',e)); print('STUN_RESULT',e.life,life,tostring(e:hasEffect(e.EFF_STUNNED)~=nil)); assert(e.life<life); out('debuff_hit')
ready(); life=e.life; assert(a.use(p,'T_DEATH_DANCE_ASSAULT')); assert(e.life<life); out('melee_aoe')
ready(); p:resetToFull(); assert(a.use(p,'T_UNSTOPPABLE')); assert(p:hasEffect(p.EFF_UNSTOPPABLE)); p:takeHit(100000,e); assert(p.life==1 and not p.dead); local before=p.life; p:heal(100,p); assert(p.life==before); out('unstoppable')

local function same(a,b)
 if type(a)~=type(b) then return false end
 if type(a)~='table' then return a==b end
 for k,v in pairs(a) do if not same(v,b[k]) then return false end end
 for k in pairs(b) do if a[k]==nil then return false end end
 return true
end
local rng_before=rng.state_get(); local turn_before=s.game.turn; local energy_before=p.energy.value
for i=1,3 do a.menu(p) end
assert(same(rng_before,rng.state_get()) and s.game.turn==turn_before and p.energy.value==energy_before,'observe changed RNG or time')
out('readonly_observe')
local active=p:hasEffect(p.EFF_UNSTOPPABLE); local dur=active.dur
for i=1,dur+1 do p:timedEffects(function(def,params) return params.effect_id==p.EFF_UNSTOPPABLE end) end
assert(not p:hasEffect(p.EFF_UNSTOPPABLE)); out('unstoppable_expiry',dur)
p:resetToFull(); p:cooldownTalents(100); ready(); assert(p:isTalentActive(p.T_ARCANE_POWER)); assert(a.use(p,'T_ARCANE_POWER')); assert(not p:isTalentActive(p.T_ARCANE_POWER) and p:getMaxMana()==mana); out('sustain_off')
if e:hasEffect(e.EFF_STUNNED) then e:removeEffect(e.EFF_STUNNED) end
e.stun_immune=1; p:cooldownTalents(100); ready(); local hp_before=e.life; assert(a.use(p,'T_STUNNING_BLOW_ASSAULT',e)); assert(e.life<hp_before and not e:hasEffect(e.EFF_STUNNED)); out('stun_immune')
local npc=s.enemies[5]; assert(not npc:hasEffect(npc.EFF_UNSTOPPABLE)); npc.max_life=10000; npc.life=10000
npc:setEffect(npc.EFF_UNSTOPPABLE,2,{hp_per_kill=0}); npc:takeHit(100000,p); assert(npc.life==1 and not npc.dead)
for i=1,3 do npc:timedEffects(function(_,params) return params.effect_id==npc.EFF_UNSTOPPABLE end) end
assert(not npc:hasEffect(npc.EFF_UNSTOPPABLE)); npc:takeHit(100000,p); assert(npc.dead); out('native_death_after_expiry')
