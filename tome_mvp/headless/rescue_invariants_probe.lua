dofile('/probe.lua')
local scenario=require 'scene'
local rescue=require 'rescue'
local s=scenario.create(11)
local p,a,b=s.allies[1],s.allies[2],s.allies[3]
local foe=s.enemy
for _,actor in ipairs(s.allies) do
    assert(actor:knowTalent('T_MERCENARY_RESCUE'))
    actor:unlearnTalent('T_MERCENARY_RESCUE',1)
    assert(actor:knowTalent('T_MERCENARY_RESCUE'),'permanent skill removed')
end
a:setEffect(a.EFF_UNSTOPPABLE,2,{hp_per_kill=0})
a:takeHit(100000,foe)
assert(a.life==1 and not rescue.is_down(a),'unstoppable lost precedence')
for i=1,3 do a:timedEffects(function(_,eff) return eff.effect_id==a.EFF_UNSTOPPABLE end) end
local kills=0
foe.on_kill=function() kills=kills+1 end
foe:setTarget(a)
a:takeHit(100000,foe)
assert(rescue.is_down(a) and kills==0 and not a.dead and not foe.ai_target.actor,'on kill/target')
foe:setTarget(a)
assert(not foe.ai_target.actor, 'enemy reacquired unconscious target')
assert(not a:useTalent(a.T_ATTACK,nil,nil,nil,p), 'unconscious talent action')
assert(not a:attackTarget(p), 'unconscious melee action')
a:removeEffect('EFF_MERCENARY_DOWN',true,true)
assert(rescue.is_down(a),'forced cleanse woke target')
a:setEffect(a.EFF_BURNING,3,{power=30,src=foe},true)
a:timedEffects(function(_,eff) return eff.effect_id==a.EFF_BURNING end)
a:heal(1000,p); a:regenLife()
assert(a.life==0 and rescue.is_down(a) and a:hasEffect(a.EFF_BURNING),'burn or heal broke lock')
local x,y=a.x,a.y
assert(not a:move(x+1,y,true) and a.x==x and a.y==y,'down movement')
foe.on_kill=nil
local other=s.enemies[2]
other:takeHit(100000,p)
assert(other.dead,'enemy survived lethal damage')
assert(p:move(a.x+1,a.y,true))
local ok,err=rescue.start(p,a); assert(ok,tostring(err))
local snapshot=require 'snapshot_experiment'
assert(not pcall(snapshot.capture,s),'saved in-progress rescue')
p:takeHit(1,foe)
assert(not rescue.progress(p) and rescue.is_down(a),'damage did not interrupt')
for i, enemy in ipairs(s.enemies) do if not enemy.dead then enemy:move(24+i,10,true); enemy.never_move=1 end end
for i=1,100 do if game.paused and p:enoughEnergy() then break end; game:tick() end
assert(p:enoughEnergy(),'no decision after interruption')
assert(rescue.start(p,a))
assert(rescue.cancel(p))
assert(rescue.is_down(a) and not rescue.progress(p),'cancel woke target')
for i=1,150 do
    local live=(game.on_tick_end and next(game.on_tick_end.fcts)) or (game.on_tick_end_custom and next(game.on_tick_end_custom.fcts)) or next(game.__coroutines)
    if game.paused and p:enoughEnergy() and not live then break end
    if game.paused and p:enoughEnergy() and live then error('decision boundary has live callbacks') end
    game:tick()
end
assert(game.paused and p:enoughEnergy(),'no save boundary after cancellation')
local doc=snapshot.capture(s)
local fresh=scenario.create(11)
local restored=snapshot.restore(doc,fresh)
assert(rescue.is_down(restored.allies[2]) and restored.allies[2].life==0,'down did not restore')
protocol_write('PASS_RESCUE_INVARIANTS\n')
