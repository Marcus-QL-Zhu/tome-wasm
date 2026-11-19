dofile('/probe.lua')
local s=require('scene').create(11);for _,e in ipairs(s.enemies) do game.level:removeEntity(e,true) end
local p=s.player;p.life=p.life-2
config.settings.player_aioo_stop_on_rare=true;config.settings.player_aioo_stop_enemy_count=0
local a=require('player_aioo').load_source(headless_aioo_source(),require('mod.class.Player'));a.start();assert(a.lifecycle_step(1,false)=='acted' and p.resting)
p.turn_procs=p.turn_procs or {};p.turn_procs.multi=p.turn_procs.multi or {};p.turn_procs.multi.marker={turns=8}
p.talents_cd[p.T_SHOOT]=8
p.life=p.max_life
for i=1,30 do if game.paused and p:enoughEnergy() then break end;a.guard_tick(function() game:tick() end) end
assert(p:enoughEnergy() and p.resting)
local cooldown=p.talents_cd[p.T_SHOOT];local marker=p.turn_procs.multi.marker.turns;local turn=game.turn
local result=a.lifecycle_step(1,true)
assert(result=='acted' and a.phase()=='explore')
assert(p.talents_cd[p.T_SHOOT]==cooldown and p.turn_procs.multi.marker.turns==marker and game.turn==turn,'duplicate base action')
print('PASS_REST_BASE_ONCE',cooldown,marker,turn,p.energy.value)

