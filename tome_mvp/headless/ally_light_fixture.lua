-- Test-only isolated optical cases for the real worker/HTTP path.
local original=require 'scene'
package.loaded.scene={create=function(seed,fixture)
 local s=original.create(seed,'exploration'); local p,a,e,m,M=s.player,s.allies[2],s.enemy,s.map,s.Map
 game.level:removeEntity(s.allies[3],true); s.allies={p,a}
 local grid=require('mod.class.Grid'):loadList('/data/general/grids/basic.lua'); game.zone.grid_list=grid
 for y=1,62 do m(10,y,M.TERRAIN,grid.WALL) end
 for y=1,9 do for x=12,24 do m.lites(x,y,false) end end
 assert(a:move(16,4,true)); a.lite=seed==12 and 0 or 3; e.lite=0
 game.zone:addEntity(game.level,e,'actor',18,4); s.enemies={e}
 if seed==13 then a.blind=1 end
 if seed==14 then a:takeHit(100000,e); assert(require('rescue').is_down(a)) end
 if seed==15 then m(17,4,M.TERRAIN,grid.WALL) end
 m.clean_fov=true; p:doFOV()
 return s
end}
dofile('/worker.lua')
