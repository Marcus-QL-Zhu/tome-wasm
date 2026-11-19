dofile('/probe.lua')
local s=require('scene').create(11);local p=s.player;local e=s.enemies[1]
e:move(8,4,true);e:learnTalent(e.T_SHOOT,true,1)
local Object=require('mod.class.Object');game.zone.object_list=Object:loadList('/data/general/objects/bows.lua')
local function wear(name)
 for _,proto in ipairs(game.zone.object_list) do if proto.name==name then local item=game.zone:finishEntity(game.level,'object',proto,-1000);item:identify(true);assert(e:wearObject(item,false,false));return end end
 error('missing '..name)
end
wear('elm longbow');wear('quiver of elm arrows');game.zone.object_list={};e.energy.value=1000;e.combat_atk_ranged=1000
for _,foe in ipairs(s.enemies) do game.level:removeEntity(foe,true) end
p.life=p.life-25;config.settings.player_aioo_stop_on_rare=true;config.settings.player_aioo_stop_enemy_count=0
local a=require('player_aioo').load_source(headless_aioo_source(),require('mod.class.Player'));a.start();assert(a.lifecycle_step(1)=='acted');assert(p.resting)
game.zone:addEntity(game.level,e,'actor',8,4)
assert(e:useTalent(e.T_SHOOT,nil,nil,nil,p,false,true),'failed to launch')
local projectile
for _,v in pairs(game.level.entities) do if v.__CLASSNAME=='mod.class.Projectile' and v.src==e then projectile=v end end
assert(projectile,'missing native projectile')
assert(e:canSee(p),'shooter cannot see player')
local hp=p.life;local x,y=p.x,p.y;local ticks=0
while ticks<50 and p.resting do a.guard_tick(function() game:tick() end);ticks=ticks+1 end
assert(not p.resting and not p.running and p.x==x and p.y==y and p.life<hp,'projectile failed to interrupt rest')
local hit_hp=p.life; local turn=game.turn
a.stop('user_stop')
local checked=false; for i=1,100 do local name,value=debug.getupvalue(a.lifecycle_step,i); if not name then break end; if name=='deferred_rest' then assert(value==nil,'old callback retained');checked=true end end; assert(checked)
assert(not p.resting and not p.running and p.x==x and p.y==y)
for i=1,20 do game:tick() end
assert(not p.running and p.x==x and p.y==y,'revoked callback resumed')
local st,reason=a.control();assert(st=='stopped' and reason=='user_stop')
a.start(); assert(a.phase()==nil); local ok=pcall(function() a.lifecycle_step(1) end); assert(not ok, 'old epoch must fail'); a.stop('user_stop')
print('PASS_REST_PROJECTILE_REVOKED',hp,hit_hp,turn,game.turn,p.x,p.y)
