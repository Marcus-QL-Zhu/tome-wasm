-- Test-only protocol wrapper: place the actor next to an existing native door.
-- No production fixture or client method exposes this setup.
local original=require 'scene'
package.loaded.scene={create=function(seed,fixture)
 local state=original.create(seed,fixture)
 local p,map,Map=state.player,state.map,state.Map
 local placed=false
 for y=1,62 do for x=1,62 do
  local g=map(x,y,Map.TERRAIN)
  if not placed and g and g.door_opened and not g.door_player_check and not g.door_player_stop then
   for _,d in ipairs({{1,0},{-1,0},{0,1},{0,-1}}) do
    local nx,ny=x+d[1],y+d[2]
    if not map:checkAllEntities(nx,ny,'block_move',p,false) then
     assert(p:move(nx,ny,true)); placed=true; break
    end
   end
  end
 end end
 assert(placed,'no native door with adjacent floor')
 map.clean_fov=true; p:doFOV()
 return state
end}
dofile('/worker.lua')
