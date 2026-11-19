dofile('/probe.lua')
local s=require('scene').create(11)
local r=require('rescue')
local p,target=s.player,s.allies[2]
target:takeHit(100000,s.enemy)
for i,foe in ipairs(s.enemies) do foe:move(24+i,10,true); foe.never_move=1 end
assert(p:move(target.x+1,target.y,true))
assert(r.start(p,target))
p:setEffect(p.EFF_STUNNED,3,{power=50},true)
assert(not r.progress(p) and r.is_down(target),'stun did not interrupt')
p:removeEffect(p.EFF_STUNNED,true,true)
for i=1,100 do if game.paused and p:enoughEnergy() then break end; game:tick() end
assert(p:enoughEnergy() and r.start(p,target))
local x,y=p.x,p.y
assert(p:move(x+1,y,true))
assert(not r.progress(p) and r.is_down(target),'displacement did not interrupt')
protocol_write('PASS_RESCUE_INTERRUPTS\n')
