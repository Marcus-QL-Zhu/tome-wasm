-- Test-only wrapper: original ToME door in a one-tile corridor.
local original=require 'scene'
package.loaded.scene={create=function(seed,fixture)
 local s=original.create(seed,fixture)
 local p,map,Map=s.player,s.map,s.Map
 local Grid=require 'mod.class.Grid'
 game.zone.grid_list=Grid:loadList('/data/general/grids/basic.lua')
 local floor,wall=game.zone.grid_list.FLOOR,game.zone.grid_list.WALL
 for i=2,#s.allies do game.level:removeEntity(s.allies[i],true) end
 s.allies={p}
 for x=1,62 do for y=1,62 do
  map(x,y,Map.TERRAIN,y==4 and x>=3 and x<=12 and floor or wall)
  map.has_seens(x,y,false)
 end end
 local door=seed==13 and game.zone.grid_list.DOOR_VAULT or game.zone.grid_list.DOOR
 map(5,4,Map.TERRAIN,door)
 if seed==12 then
  game.zone:addEntity(game.level,s.enemy,'actor',7,4)
  s.enemies={s.enemy}
 end
 if seed==14 then assert(p:move(3,4,true)) end
 map.clean_fov=true; p:doFOV()
 return s
end}
dofile('/worker.lua')
