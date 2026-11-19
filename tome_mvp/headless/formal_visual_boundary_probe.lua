dofile('/probe.lua')
local s=require('scene').create(11,'formal')
local visibility=require 'visibility'
local Map=require 'engine.Map'
visibility.refresh(s)
local index=next(s.shared_seen)
assert(index,'no initially visible tile')
local x,y=index%64,math.floor(index/64)
local before=assert(s.terrain_memory[index]).image
for _,a in ipairs(s.allies) do a.blind=1 end
s.map.seens(x,y,false)
local current=s.map(x,y,Map.TERRAIN)
local replacement=s.game.zone.grid_list[current.name=='wall' and 'FLOOR' or 'WALL']
assert(replacement and replacement.image~=current.image)
s.map(x,y,Map.TERRAIN,replacement)
visibility.refresh(s)
assert(not s.shared_seen[index] and s.terrain_memory[index].image==before,'hidden terrain change leaked')
print('FORMAL_HIDDEN_TERRAIN_MEMORY_PASS',x,y,before,replacement.image)
