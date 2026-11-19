local json = require 'json_validate'
rng.seed(827)
rng.normalFloat(0, 1)
local s = rng.state_get()
s.words = json.array(s.words)
local expected = json.array({rng.normalFloat(0, 1), rng.range(1, 1000000), rng.float(0, 1)})
protocol_write(json.encode(json.object({state=json.object(s),expected=expected})) .. "\n")
