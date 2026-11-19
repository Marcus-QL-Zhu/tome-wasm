dofile('/probe.lua')
local state=require('scene').create(11)
local zone=require('formal_factory').new_zone()
state.player.open_door=true
for _,seed in ipairs({11,12,13}) do
 rng.seed(seed)
 local result=require('formal_map').create(zone,state.player)
 print('FORMAL_ROOMS',seed,result.attempts,result.reachable,#result.wide)
end
