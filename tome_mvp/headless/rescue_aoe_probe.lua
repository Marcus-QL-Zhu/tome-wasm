dofile('/probe.lua')
local s=require('scene').create(11)
local rescue=require('rescue')
local p,a,b=s.allies[1],s.allies[2],s.allies[3]
assert(b:move(3,3,true))
local foe=s.enemy
local DamageType=require 'engine.DamageType'
foe:project({type='ball',range=5,radius=2},p.x,p.y,DamageType.FIRE,100000)
for _,actor in ipairs(s.allies) do
    assert(rescue.is_down(actor) and actor.life==0 and not actor.dead, 'area damage did not down party')
    actor:takeHit(10000,foe)
    assert(actor.life==0 and not actor.dead)
end
protocol_write('PASS_RESCUE_AOE_ALL_THREE\n')
