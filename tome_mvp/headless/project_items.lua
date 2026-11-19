-- Project-authored ordinary objects. Private content remains in the ledger.
local M={}
function M.install(list)
 local Object=require 'mod.class.Object'
 local found
 for _,p in ipairs(list) do
  if p.name=='ordinary document' then
   assert(not found,'duplicate document prototype')
   assert(p._dm_project_document==true and p.type=='misc' and p.subtype=='document' and p.stacking==false and not p.unique and not p.artifact and not p.use_simple and not p.use_power and not p.wielder,'invalid document prototype')
   found=p
  end
 end
 if found then return end
 list[#list+1]=Object.new{
  name='ordinary document', type='misc', subtype='document',
  desc='An ordinary paper document.', display='?',
  identified=true, encumber=0, stacking=false,
  not_in_stores=true, _dm_project_document=true,
 }
end
return M
