-- Move a confirmed native item root and its exclusively owned ordinary data.
-- This runs only in an isolated transaction candidate; all touched owners must
-- be re-emitted and committed together, or the candidate must be discarded.
local P=require 'native_save_partition'
local M={}
function M.to_owner(item,registry,writer,roots,protected,target,allow_parked_cursor)
 local id=assert(registry:ref(item),'native item has no persistent ref')
 local entry=assert(registry:entry(id),'unknown native item')
 local source=entry.owner
 target=target or 'hot'
 if source==target then return {} end
 local promoting=entry.class=='mod.class.NPC' and item._dm_histfig_id and target=='hot'
 assert(entry.kind=='entity' and (entry.class=='mod.class.Object' or promoting),'unsupported moving native entity')
 assert(roots[source],'source partition is not resident')
 assert(type(writer)=='table','shared native function writer required')
 local protected_set={};for _,ref in ipairs(protected or {})do protected_set[ref]=true end
 registry:transfer(id,source,target)
 local touched={[source]=true,[target]=true}
 local retained={}
 local function retain_from(root)
  local data=P.export({{owner=source,root=root}},registry,writer,{allow_parked_cursor=allow_parked_cursor})
  local part=data.parts[source]
  for ref in pairs(part.fragments)do retained[ref]=true end
  for ref in pairs(part.functions)do retained[ref]=true end
 end
 retain_from(roots[source])
 -- Published external strong refs anchor their entire native subgraph.
 for ref in pairs(protected_set)do
  local e=registry:entry(ref)
  if e and e.owner==source and not retained[ref] then
   local live=assert(registry:live(ref),'protected source object is not resident')
   if e.kind=='function' then retained[ref]=true else retain_from(live) end
  end
 end
 -- Native Zone finishing stores cloned base and ego Object instances here.
 -- Other Object references do not imply ownership.
 local contained={}
 local function discover(o)
  if contained[o] then return end;contained[o]=true
  local original=rawget(o,'__original')
  if type(original)=='table' and rawget(original,'__CLASSNAME')=='mod.class.Object' then discover(original) end
  for _,ego in ipairs(rawget(o,'ego_list') or {})do
   local child=type(ego)=='table' and ego[1]
   if type(child)=='table' and rawget(child,'__CLASSNAME')=='mod.class.Object' then discover(child) end
  end
 end
 if promoting then
  for _,inv in pairs(item.inven or {})do
   for _,base in ipairs(inv)do
    base:forAllStack(function(o)discover(o);if o.tinker then discover(o.tinker) end end)
   end
  end
 else discover(item) end
 local rounds=0
 while true do
  rounds=rounds+1;assert(rounds<=1000,'native item ownership closure limit')
  local data=P.export({{owner=target,root=item}},registry,writer,{allow_parked_cursor=allow_parked_cursor})
  local moved=0
  for ref in pairs(data.parts[target].strong_refs)do
   local e=assert(registry:entry(ref),'missing item reference')
   local object=registry:live(ref)
   if e.kind=='entity' and e.class=='mod.class.Object' and object and contained[object] and e.owner==source and not retained[ref] and not protected_set[ref] then
    registry:transfer(ref,source,target);touched[source]=true;moved=moved+1
   elseif e.kind=='table' and e.owner==source and not retained[ref] and not protected_set[ref] then
    registry:transfer(ref,source,target);touched[source]=true;moved=moved+1
   elseif target=='hot' and e.kind=='function' and e.owner~='hot' then
    local fn=assert(registry:live(ref),'native function owner is not resident')
    assert(type(fn)=='function' and roots[e.owner],'native function partition is not resident')
    local catalog=native_catalog_anchor_enabled and require('native_catalog_anchor').identify(fn)
    if not catalog then writer:classify(fn) end
    local previous=e.owner;registry:transfer(ref,previous,'hot');touched[previous]=true;moved=moved+1
   end
  end
  if moved==0 then return touched end
 end
end
function M.to_hot(item,registry,writer,roots,protected,allow_parked_cursor)return M.to_owner(item,registry,writer,roots,protected,'hot',allow_parked_cursor)end
return M
