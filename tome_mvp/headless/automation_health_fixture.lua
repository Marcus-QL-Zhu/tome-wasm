-- Test-only: start with one teammate already in a severe health episode.
local original=require 'scene'
package.loaded.scene={create=function(seed,fixture)
 local s=original.create(seed,fixture)
 s.allies[2].life=s.allies[2].max_life*0.1
 return s
end}
dofile('/worker.lua')
