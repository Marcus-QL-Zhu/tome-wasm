dofile('/probe.lua')
local state=require('scene').create(7)
local aioo=require('player_aioo').load('/player_aioo_original.lua',require('mod.class.Player'))
config.settings.player_aioo_stop_on_rare=true
config.settings.player_aioo_stop_enemy_count=0
print('AIOO_LOADED',type(aioo.combat_step),#aioo.spot_hostiles(state.player,true))
local result=aioo.combat_step()
print('AIOO_STEP',result)
