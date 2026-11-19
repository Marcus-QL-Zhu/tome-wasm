-- Test-only normal armor underfoot; seed 12 adds native interesting terrain.
local original=require 'scene'
package.loaded.scene={create=function(seed,fixture)
 local s=original.create(seed,fixture)
 local Object=require 'mod.class.Object'
 local o=Object.new{name='ordinary test cloak',type='armor',subtype='cloak',encumber=1}
 local x,y=5,3
 s.map:addObject(x,y,o)
 if seed==13 then
  local old=s.player.runStep; local tested=false
  s.player.runStep=function(self,...)
   if not tested and self.running then
    tested=true; local ox,oy=self.x,self.y; self.x,self.y=x,y
    local before=s.map.attrs(x,y,'obj_seen'); self:runCheck(true)
    assert(s.map.attrs(x,y,'obj_seen')==before,'phantom runCheck changed object memory')
    self.x,self.y=ox,oy
   end
   return old(self,...)
  end
 end
 if seed==12 then
  local grid=s.map(x,y,s.Map.TERRAIN)
  grid.notice=true
 end
 return s
end}
dofile('/worker.lua')

