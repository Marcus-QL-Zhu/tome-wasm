dofile('/probe.lua')
local s=require('scene').create(11)
local reports={};local report=profile.sendError
profile.sendError=function(self,...)reports[#reports+1]={...};return report(self,...)end
require('native_zone').difficulty({})
local actor=require('mod.class.NPC').new{name='Retaliation ledger probe',on_melee_hit={}}
local dtype=require('engine.DamageType').COLD
local old=actor:addTemporaryValue('on_melee_hit',{[dtype]=17})
assert(actor.on_melee_hit[dtype]==17)
headless_before_retal_clear(actor)
actor.on_melee_hit={}
local fresh=actor:addTemporaryValue('on_melee_hit',{[dtype]=5})
assert(actor.on_melee_hit[dtype]==5)
actor:removeTemporaryValue('on_melee_hit',old)
assert(actor.on_melee_hit[dtype]==5,'old offset removed a new source')
actor:removeTemporaryValue('on_melee_hit',fresh)
assert(not actor.on_melee_hit[dtype] or actor.on_melee_hit[dtype]==0,'new offset leaked')
local untouched=actor:addTemporaryValue('combat_armor',9)
actor:removeTemporaryValue('combat_armor',untouched)
assert(#reports==0,'native error hidden by ledger repair')
protocol_write('PASS_NATIVE_ZONE_RETALIATION_LEDGER\n')
