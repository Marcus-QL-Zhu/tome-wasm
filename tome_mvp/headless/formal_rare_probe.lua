dofile('/probe.lua')
local state=require('scene').create(11)
local factory=require 'formal_factory'
local zone=factory.new_zone()
for i,lev in ipairs({15,16,17,18,20}) do
 local e=factory.add_rare(zone,game.level,lev,20+i,28)
 local n=0 for _,rank in pairs(e.talents) do if rank>0 then n=n+1 end end
 assert(n>2 and e:getInven('MAINHAND')[1] and e:getInven('OFFHAND')[1] and e.life==e.max_life)
 print('FORMAL_NATIVE_RARE',e.uid,e.rank,e.level,table.concat(e.descriptor.classes or {},','),n,e.max_life)
end
