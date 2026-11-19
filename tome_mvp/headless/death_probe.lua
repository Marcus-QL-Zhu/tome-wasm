dofile('/probe.lua')
local s=require('scene').create(11)
for i=2,#s.enemies do s.enemies[i]:takeHit(10000,s.player) end
local e=s.enemies[1]
e.life=1
local energy=s.player.energy.value
s.player:move(e.x,e.y)
assert(s.player.energy.value<energy,'native attack did not consume energy')
assert(e.dead,'ordinary human enemy survived native attack')
for _,foe in ipairs(s.enemies) do assert(foe.dead) end
protocol_write('PASS_NATIVE_HUMAN_DEATH_AND_EMPTY_ENEMIES\n')
