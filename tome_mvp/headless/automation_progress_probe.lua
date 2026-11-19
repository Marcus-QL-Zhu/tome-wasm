-- Isolated proof: original guard remains; host progress reset changes only its counter.
dofile('/probe.lua')
local s=require('scene').create(11)
config.settings.player_aioo_stop_on_rare=false; config.settings.player_aioo_stop_enemy_count=0
local a=require('player_aioo').load_source(headless_aioo_source(),require('mod.class.Player'))
a.start('sweep'); assert(a.lifecycle_step(1)=='acted')
for i=1,30 do if game.paused and s.player:enoughEnergy() then break end;a.guard_tick(function() game:tick() end) end
local found=false
for i=1,100 do local name=debug.getupvalue(a.class.act,i); if not name then break end; if name=='aiTurnCount' then debug.setupvalue(a.class.act,i,500);found=true;break end end
assert(found and a.native_turn_count()==500)
a.progress_reset(); assert(a.native_turn_count()==0)
local result=a.lifecycle_step(1); assert(result=='acted',result)
print('PASS_AIOO_PROGRESS_RESET',a.native_turn_count())
