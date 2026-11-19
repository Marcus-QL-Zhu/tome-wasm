dofile('/probe.lua')
local s=require('scene').create(11)
s.player:move(4,10,true)
s.map.clean_fov=true; s.player:doFOV()
local aioo=require('player_aioo').load_source(headless_aioo_source(),require('mod.class.Player'))
config.settings.player_aioo_stop_on_rare=true; config.settings.player_aioo_stop_enemy_count=0
local weight=1; s.player.ai_talents={T_SHOOT=weight}
local q=s.player:getInven('QUIVER'); print('START',s.player.x,s.player.y,q[1].combat.shots_left,weight)
aioo.start()
for n=1,10 do
 local ok,ret=xpcall(function() return aioo.combat_step(1) end,debug.traceback)
 print('POLICY_STEP',n,ok,ret,'ammo',q[1].combat.shots_left,'tid',s.player.ai_state.last_tid,'turn',game.turn)
 if not ok or ret~='acted' then break end
 for i=1,30 do if game.paused and s.player:enoughEnergy() then break end; game:tick() end
end
