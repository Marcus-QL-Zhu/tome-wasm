dofile('/probe.lua')
local json=require 'json_validate'
local input=assert(json.decode(protocol_read()))
local state=require('snapshot_experiment').restore(input.doc,require('scene').create(11))
assert(state.navigation_memory[4031].blocked and state.navigation_memory[4031].unsafe,'navigation memory not restored')
protocol_write('PASS_NAVIGATION_MEMORY_CROSS_PROCESS\n')
