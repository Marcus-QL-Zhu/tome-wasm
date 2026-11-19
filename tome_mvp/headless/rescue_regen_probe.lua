dofile('/probe.lua')
local s=require('scene').create(11)
local r=require 'rescue'
local a,b=s.player,s.allies[2]
local baseline=b:attr('no_life_regen')or 0
local external=b:addTemporaryValue('no_life_regen',1)
b:takeHit(100000,s.enemy)
assert(r.is_down(b) and (b:attr('no_life_regen')or 0)==baseline+2,'down regen restriction missing')
b:heal(1000,a);b:regenLife()
assert(b.life==0,'down actor regenerated')
assert(a:move(b.x+1,b.y,true))
local ok,err=r.start(a,b);assert(ok,tostring(err))
for i=2,20 do a.energy.value=game.energy_to_act;assert(r.step(a))end
assert(r.is_down(b) and r.progress(a).completed==20,'rescue duration changed')
a.energy.value=game.energy_to_act;assert(r.step(a))
assert(not r.is_down(b) and b.life==b.max_life*.2,'rescue result changed')
assert((b:attr('no_life_regen')or 0)==baseline+1,'external regen restriction removed')
b:removeTemporaryValue('no_life_regen',external)
assert((b:attr('no_life_regen')or 0)==baseline,'effect regen restriction leaked')
b:takeHit(100000,s.enemy);assert(r.is_down(b))
r.withdraw_leader(b)
assert(not r.is_down(b) and b.life==1 and (b:attr('no_life_regen')or 0)==baseline,'withdrawal regen restriction leaked')
protocol_write('PASS_RESCUE_REGEN_LIFECYCLE\n')
