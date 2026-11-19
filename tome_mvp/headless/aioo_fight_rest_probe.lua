dofile('/probe.lua')
local s=require('scene').create(11);local p=s.player
config.settings.player_aioo_stop_on_rare=true;config.settings.player_aioo_stop_enemy_count=0
local a=require('player_aioo').load_source(headless_aioo_source(),require('mod.class.Player'));a.start();assert(a.lifecycle_step(1)=='acted');assert(a.phase()=='fight')
for _,e in ipairs(s.enemies) do game.level:removeEntity(e,true) end
p.life=p.life-10
for i=1,30 do if game.paused and p:enoughEnergy() then break end;a.guard_tick(function() game:tick() end) end
assert(p:enoughEnergy());s.map.clean_fov=true;p:doFOV()
local old=game.turn;local st=a.lifecycle_step(1);assert(st=='acted' and a.phase()=='rest' and p.resting,'fight did not transition to rest')
print('PASS_FIGHT_REST',st,a.phase(),old,game.turn,p.life)
