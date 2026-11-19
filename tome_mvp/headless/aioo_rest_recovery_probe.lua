dofile('/probe.lua')
local state=require('scene').create(11)
for _,foe in ipairs(state.enemies) do game.level:removeEntity(foe, true) end
local emit=state.map.particleEmitter
state.map.particleEmitter=function(self,x,y,r,kind,...) if kind=='dust_trail' then return end return emit(self,x,y,r,kind,...) end
state.player.life=state.player.life-25
local q=state.player:getInven('QUIVER'); q[1].combat.shots_left=q[1].combat.shots_left-5
print('RECOVERY_BEFORE',state.player.life,q[1].combat.shots_left)
local aioo=require('player_aioo').load_source(headless_aioo_source(),require('mod.class.Player'))
config.settings.player_aioo_stop_on_rare=true
config.settings.player_aioo_stop_enemy_count=0
aioo.start()
local ok,err=xpcall(function() aioo.lifecycle_step(1) end,debug.traceback)
print('REST_EXPLORATION_PROBE',ok,err,'running',tostring(state.player.running),'resting',tostring(state.player.resting),'turn',game.turn,'energy',state.player.energy.value)
local function output(label) print(label,'turn',game.turn,'position',state.player.x,state.player.y,'energy',state.player.energy.value,'running',tostring(not not state.player.running),'resting',tostring(not not state.player.resting)) end
if ok then
    output('FIRST')
    for n=1,5 do
        for i=1,100 do
            if state.player:enoughEnergy() then break end
            state.player.restStep=function() return false end
            state.player.runStep=function() return false end
            game:tick()
            state.player.restStep=nil; state.player.runStep=nil
        end
        if not state.player:enoughEnergy() then error('decision budget exceeded') end
        if state.player.running or state.player.resting then aioo.lifecycle_step(1) else break end
        output('STEP'..n)
    end
    local okstop,stoperr=xpcall(function() aioo.stop('user_stop') end,debug.traceback)
    print('STOP',okstop,stoperr,'recovery',state.player.life,q[1].combat.shots_left,'running',tostring(state.player.running),'resting',tostring(state.player.resting)); assert(okstop and not state.player.running and not state.player.resting)
end
