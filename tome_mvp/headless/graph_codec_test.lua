local json=require 'json_validate'
local codec=require 'graph_codec'
local marker=function() end
local mt={__index={marker=marker}}
local a=setmetatable({},mt)
local b={}
a.self=a; a.alias=b; a[b]=b; b.owner=a
local doc=codec.encode(a,{[marker]='marker'})
local restored=codec.decode(assert(json.decode(json.encode(doc))),{marker=marker})
assert(restored.self==restored and restored[restored.alias]==restored.alias)
assert(restored.alias.owner==restored and restored.marker==marker)
assert(not pcall(codec.encode,{bad=function() end},{}))
assert(not pcall(codec.decode,doc,{}))
protocol_write('PASS_GRAPH_CYCLES_ALIASES_AND_REJECTION\n')
