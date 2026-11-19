-- Test-only adaptation: drive native autoExplore's replan of an active route.
local factory=require 'player_aioo'
local original_load=factory.load_source
factory.load_source=function(...)
 local controller=original_load(...)
 local step=controller.lifecycle_step
 local calls=0
 controller.lifecycle_step=function(...)
  calls=calls+1
  local p=game.player
  if calls==2 then
   assert(p.x==4 and p.y==4 and p.running and p.running.dialog)
   local dialog=p.running.dialog
   p.running={path={{x=4,y=4}},cnt=2,explore='unseen',target={x=4,y=4},dialog=dialog,ave_x=4,ave_y=4,ave_N=2,levelstring=tostring(game.level)}
   p.running_prev=p.running
   local old=rawget(p,'runStep')
   p.runStep=function(self) return self:autoExplore() end
   local result=step(...)
   p.runStep=old
   return result
  end
  return step(...)
 end
 return controller
end
local scene=require 'scene'
package.loaded.scene={create=function(seed,fixture)
 local s=scene.create(seed,fixture)
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
 map(5,4,Map.TERRAIN,game.zone.grid_list.DOOR)
 assert(p:move(3,4,true)); map.clean_fov=true;p:doFOV()
 return s
end}
dofile('/worker.lua')
