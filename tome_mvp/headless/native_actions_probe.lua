-- Standalone host probe. Expects the prepared headless bootstrap /probe.lua.
dofile('/probe.lua')
local state=require('scene').create(7)
local actions=require('native_actions')
local p,e,map=state.player,state.enemy,state.map
world=require('mod.class.World').new()
core.key={modState=function(k) assert(k=='ctrl'); return false end}
local arrows=assert(p:getInven('QUIVER')[1])
e:move(7,4,true); map.clean_fov=true; p:doFOV()
local n=arrows.combat.shots_left
arrows.combat.shots_left=0
local empty=actions.shoot(p,e)
assert(not empty and arrows.combat.shots_left==0,'empty quiver accepted')
arrows.combat.shots_left=n
local floor=map(6,4,state.Map.TERRAIN)
local wall=require('mod.class.Grid').new{name='wall',type='wall',subtype='wall',display='#',block_move=true,block_sight=true}
map(6,4,state.Map.TERRAIN,wall); map.clean_fov=true; p:resetCanSeeCache(); p:doFOV()
local blocked=actions.shoot(p,e)
assert(not blocked and arrows.combat.shots_left==n,'blocked shot was accepted')
map(6,4,state.Map.TERRAIN,floor); map.clean_fov=true; p:resetCanSeeCache(); p:doFOV()
assert(actions.shoot(p,e))
assert(arrows.combat.shots_left==n-1)
local projectile
for _,v in ipairs(state.game.level.e_array) do
    if v.__CLASSNAME=='mod.class.Projectile' then projectile=v end
end
assert(projectile and projectile.src==p, 'missing native projectile')
local hp=e.life
local n_tick=0
repeat
    if state.game.paused and p:enoughEnergy() then p:waitTurn() end
    state.game:tick(); n_tick=n_tick+1
until not state.game.level:hasEntity(projectile) or n_tick>=120
assert(not state.game.level:hasEntity(projectile), 'projectile not resolved')
assert(e.life<hp, 'projectile did not hit target in this seeded probe')
print('NATIVE_SHOOT_LANDED_PASS',n_tick,n,arrows.combat.shots_left,hp,e.life)
