dofile('/probe.lua')
local state=require('scene').create(11,'formal')
local seen={}
for i,member in ipairs(state.formal_differences) do
 assert(#member.equipment==({13,12,12})[i]); assert(#member.inscriptions==({3,4,4})[i])
 for _,v in ipairs(member.equipment) do assert(v.worn and v.uid and not seen[v.uid]); seen[v.uid]=true; print('WORN',i,v.slot,v.source_name,v.actual_name,v.uid,v.inven,v.inven_slot,v.matched_egos) end
 for _,v in ipairs(member.inscriptions) do print('INSCRIPTION',i,v.slot,v.talent) end
end
print('FORMAL_EQUIPMENT_PASS',37,11)
