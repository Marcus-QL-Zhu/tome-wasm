dofile('/probe.lua')
local s=require('scene').create(11)
local r=require('rescue')
local p, target=s.player,s.allies[2]
for _,foe in ipairs(s.enemies) do foe:move(24+_,10,true); foe.never_move=1 end
local foe=s.enemies[1]
foe.talents_cd[foe.T_SHOOT]=100
target:takeHit(10000,foe)
assert(r.is_down(target))
assert(p:move(target.x+1,target.y,true))
local function boundary()
    local n=0
    while not (game.paused and p:enoughEnergy()) do
        local old=rawget(p,'restStep')
        if r.progress(p) then p.restStep=function() return false end end
        game:tick()
        p.restStep=old
        n=n+1; assert(n<300,'scheduler did not reach decision')
    end
    return n
end
boundary()
local start_turn=game.turn
local cooldown=foe.talents_cd[foe.T_SHOOT]
local ok,err=r.start(p,target); assert(ok,tostring(err))
for count=1,20 do
    boundary()
    local progress=assert(r.progress(p),'rescue ended early')
    assert(progress.completed==count, 'unexpected progress '..tostring(progress.completed)..' expected '..count)
    assert(r.is_down(target),'target woke before 20th action elapsed')
    if count<20 then ok,err=r.step(p); assert(ok,tostring(err)) end
end
assert(foe.talents_cd[foe.T_SHOOT]<cooldown, 'enemy did not take native turns')
ok,err=r.step(p); assert(ok,tostring(err))
assert(not r.is_down(target) and target.life==target.max_life*.2)
assert(game.turn>start_turn)
protocol_write('PASS_RESCUE_SCHEDULER_20\n')
