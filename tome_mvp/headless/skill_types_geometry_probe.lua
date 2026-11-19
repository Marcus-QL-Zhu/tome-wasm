dofile('/probe.lua')
local s=require('scene').create(7); local p=s.player; local a=require('native_actions'); require('skill_types').install(p); p:resetToFull()
local e1,e2,side,outer=s.enemies[1],s.enemies[2],s.enemies[3],s.enemies[4]
for _,e in ipairs(s.enemies) do e.max_life=10000; e.life=10000; e.energy.value=-100000 end
for _,v in ipairs(s.allies) do if v~=p then v.energy.value=-100000 end end
e1:move(6,4,true); e2:move(8,4,true); side:move(7,5,true); outer:move(11,6,true); s.map.clean_fov=true; p:doFOV(); p.energy.value=1000
local h1,h2,h3=e1.life,e2.life,side.life
assert(a.use(p,'T_LIGHTNING',e2)); assert(e1.life<h1 and e2.life<h2 and side.life==h3); print('GEOMETRY_PASS','beam',h1-e1.life,h2-e2.life,h3-side.life)
e1:move(6,6,true); e2:move(7,7,true); side:move(11,4,true); s.map.clean_fov=true; p:doFOV(); p.energy.value=1000
h1,h2,h3=e1.life,e2.life,side.life
assert(a.use(p,'T_FIREFLASH',{x=7,y=6})); local proj
for _,v in ipairs(s.game.level.e_array) do if v.__CLASSNAME=='mod.class.Projectile' then proj=v end end
assert(proj); local ticks=0
repeat if s.game.paused and p:enoughEnergy() then p:waitTurn() end; s.game:tick(); ticks=ticks+1 until not s.game.level:hasEntity(proj) or ticks>=120
assert(not s.game.level:hasEntity(proj) and e1.life<h1 and e2.life<h2 and side.life==h3); print('GEOMETRY_PASS','fireflash',ticks,h1-e1.life,h2-e2.life,h3-side.life)
