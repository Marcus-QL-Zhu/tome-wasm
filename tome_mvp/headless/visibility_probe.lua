dofile('/probe.lua')
local s=require('scene').create(11)
local visibility=require 'visibility'
local ally=s.allies[2]
local distant,hidden,behind=s.enemies[2],s.enemies[3],s.enemies[4]
ally:move(20,4,true)
distant:move(24,4,true)
hidden:move(21,5,true); hidden.invisible=100
behind:move(34,4,true)
s.map.clean_fov=true; s.player:doFOV(); visibility.refresh(s)
assert(not s.player_visible[distant.uid] and s.visible[distant.uid], 'ally-only enemy not shared')
assert(not s.visible[hidden.uid], 'hidden enemy leaked')
assert(not s.visible[behind.uid], 'wall enemy leaked')
assert(s.shared_seen[distant.x+distant.y*s.map.w], 'ally-only terrain not shared')
protocol_write('PASS_SHARED_FOV_AND_CONCEALMENT\n')
