dofile('/probe.lua')
local actor=require('scene').create(11).player
local project=require('resource_projection').public
local json=require 'json_validate'
actor:learnTalent(actor.T_STAMINA_POOL,true,1)
local old=actor.max_stamina
local value=actor.stamina
actor.max_stamina=nil -- isolated observation-contract test only
local found
for _,item in ipairs(project(actor)) do if item.id=='stamina' then found=item end end
assert(found and found.value==value and found.max==json.null and type(found.min)=='number')
actor.max_stamina=old
print('FORMAL_RESOURCE_UNKNOWN_MAX',value,found.min)
