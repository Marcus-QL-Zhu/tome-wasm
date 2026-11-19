-- Test-only: place the player at a native door with an unseen cell behind it.
local original=require 'scene'
package.loaded.scene={create=function(seed,fixture)
 local s=original.create(seed,fixture); local p,m,M=s.player,s.map,s.Map
 for y=2,61 do for x=2,61 do
  local g=m(x,y,M.TERRAIN)
  if g and g.door_opened and not g.door_player_check and not g.door_player_stop then
   for _,d in ipairs({{1,0},{-1,0},{0,1},{0,-1}}) do
    local ax,ay=x-d[1],y-d[2]; local bx,by=x+d[1],y+d[2]
    if not m:checkAllEntities(ax,ay,'block_move',p,false) and not m:checkAllEntities(bx,by,'block_move',p,false) and not m(ax,ay,M.ACTOR) and not m(bx,by,M.ACTOR) then
     assert(p:move(ax,ay,true)); m.clean_fov=true; p:doFOV(); require('visibility').refresh(s)
     if not s.shared_seen[bx+by*m.w] then return s end
    end
   end
  end
 end end
 error('no suitable native door')
end}
dofile('/worker.lua')
