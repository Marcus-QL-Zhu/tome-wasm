local json=require 'json_validate'
local M={}
local function number_or_null(value)
 if type(value)=='number' and value==value and math.abs(value)<math.huge then return value end
 return json.null
end
function M.public(actor)
 local out=json.array()
 for _,r in ipairs(actor.resources_def or {}) do
  if not r.talent or actor:knowTalent(r.talent) then
   out[#out+1]=json.object({id=r.short_name,name=r.name,value=number_or_null(actor[r.short_name]),min=number_or_null(actor[r.minname]),max=number_or_null(actor[r.maxname]),regen=number_or_null(r.regen_prop and actor[r.regen_prop]),invert_values=r.invert_values and true or false,switch_direction=r.switch_direction and true or false})
  end
 end
 return out
end
return M
