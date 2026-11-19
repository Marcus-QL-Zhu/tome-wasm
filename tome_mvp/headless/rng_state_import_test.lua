local json = require 'json_validate'
local input = assert(json.decode(protocol_read()))
rng.seed(1)
rng.state_set(input.state)
assert(input.expected[1] == rng.normalFloat(0, 1))
assert(input.expected[2] == rng.range(1, 1000000))
assert(input.expected[3] == rng.float(0, 1))
protocol_write('PASS_CROSS_PROCESS_SFMT_NORMAL\n')
