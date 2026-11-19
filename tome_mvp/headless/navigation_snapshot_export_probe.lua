dofile('/probe.lua')
local s=require('scene').create(11)
s.player:waitTurn()
for i=1,30 do if game.paused and s.player:enoughEnergy() then break end; game:tick() end
require('visibility').refresh(s); require('navigation').capture(s,s.player)
s.navigation_memory[4031]={blocked=true,unsafe=true}
local doc=require('snapshot_experiment').capture(s)
protocol_write(require('json_validate').encode(require('json_validate').object({doc=doc}))..'\n')
