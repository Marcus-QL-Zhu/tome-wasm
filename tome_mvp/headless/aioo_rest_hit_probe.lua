dofile('/probe.lua')
local s=require('scene').create(11)
for _,foe in ipairs(s.enemies) do game.level:removeEntity(foe,true) end
s.player.life=s.player.life-25
config.settings.player_aioo_stop_on_rare=true;config.settings.player_aioo_stop_enemy_count=0
local a=require('player_aioo').load_source(headless_aioo_source(),require('mod.class.Player'));a.start();assert(a.lifecycle_step(1)=='acted');assert(s.player.resting)
local old=s.player.life;local x,y=s.player.x,s.player.y
a.guard_tick(function() s.player:takeHit(10,s.allies[2]) end)
assert(not s.player.resting and not s.player.running and s.player.x==x and s.player.y==y and s.player.life<old)
print('PASS_REST_HIT_GUARD',old,s.player.life,game.turn,s.player.x,s.player.y)
