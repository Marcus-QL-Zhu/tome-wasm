-- Project-specific native item affix. Values are deterministic for the fixed
-- template source identity and fixed project seed; callers supply no bonus.
local M={}
local eligible={FINGER=true,NECK=true}
function M.install(state,seed)
 for _,actor in ipairs(state.allies) do
  local candidates={}
  for _,slot in ipairs(actor.inven_def or {}) do
   if eligible[slot.short_name] then
    for _,item in ipairs(actor:getInven(slot.id) or {}) do
     candidates[#candidates+1]=item
    end
   end
  end
  table.sort(candidates,function(a,b) return (a.formal_source_name or a.name)<(b.formal_source_name or b.name) end)
  if #candidates>0 then
   local item=candidates[1]
   assert(not item._dm_cha_affix,'CHA affix already assigned')
   local key=assert(item.formal_source_name or item.name,'missing item source')
   local hash=129; for i=1,#key do hash=(hash*33+key:byte(i))%65521 end
   item._dm_cha_affix={id='mercenary-charisma-v1',source='project_generated',value=1+(hash%3)}
  end
 end
end
function M.bonus(item)
 local affix=item._dm_cha_affix
 if not affix then return 0 end
 assert(affix.id=='mercenary-charisma-v1' and affix.source=='project_generated' and type(affix.value)=='number' and affix.value>=1 and affix.value<=3 and affix.value==math.floor(affix.value),'invalid CHA affix')
 return affix.value
end
return M
