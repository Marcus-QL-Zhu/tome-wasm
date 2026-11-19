dofile('/probe.lua')
local s=require('scene').create(11)
local r=require('rescue')
local a,b=s.player,s.allies[2]
local olduid=b.uid
b:takeHit(10000,s.enemy)
assert(r.is_down(b) and b.life==0 and not b.dead and b.uid==olduid, 'lethal damage')
b:heal(1000,a); b:regenLife(); b:takeHit(1000,s.enemy)
assert(b.life==0 and not b.dead, 'down life lock')
assert(not s.enemy:canSee(b), 'enemy can see down target')
assert(not r.can_rescue(a,a))
assert(a:move(b.x+1,b.y,true))
local ok,err=r.start(a,b); assert(ok,tostring(err))
for i=2,20 do a.energy.value=game.energy_to_act; ok,err=r.step(a); assert(ok,tostring(err)) end
assert(r.is_down(b) and r.progress(a).completed==20, 'premature rescue')
a.energy.value=game.energy_to_act; ok,err=r.step(a); assert(ok,tostring(err))
assert(not r.is_down(b) and b.life==b.max_life*.2 and b.uid==olduid, 'completion')
protocol_write('PASS_RESCUE_BASIC\n')
