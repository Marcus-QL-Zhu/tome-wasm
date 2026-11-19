dofile('/probe.lua')
local s=require('scene').create(11)
config.settings.player_aioo_stop_on_rare=true; config.settings.player_aioo_stop_enemy_count=0
local a=require('player_aioo').load_source(headless_aioo_source(),require('mod.class.Player'))
a.start(); assert(a.lifecycle_step(1)=='acted')
for i=1,30 do if game.paused and s.player:enoughEnergy() then break end;game:tick() end
local found=false
for i=1,100 do local name=debug.getupvalue(a.class.act,i); if not name then break end; if name=='aiTurnCount' then debug.setupvalue(a.class.act,i,500);found=true;break end end
assert(found,'missing original counter')
local before=game.turn; local result=a.lifecycle_step(1);local status,reason,epoch=a.control()
assert(result=='stopped' and status=='stopped' and reason:find('500 turns',1,true) and before==game.turn)
print('PASS_AIOO_ORIGINAL_500_GUARD',status,reason,epoch,before)
