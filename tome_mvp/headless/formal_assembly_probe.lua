-- Assembly-only probe: these empty modules do not represent equipment or
-- inscriptions and must never be used by a real battle or formal acceptance.
dofile('/probe.lua')
package.loaded.formal_equipment={equip=function() return {} end}
package.loaded.formal_inscriptions={install=function() return {} end}
local state=require('scene').create(11,'formal')
assert(#state.allies==3 and #state.enemies==5)
assert(state.map.w==64 and state.map.h==64)
for _,e in ipairs(state.enemies) do assert(e.rank==3.2 and e.life==e.max_life) end
print('FORMAL_ASSEMBLY_ONLY',state.map.w,#state.allies,#state.enemies)
