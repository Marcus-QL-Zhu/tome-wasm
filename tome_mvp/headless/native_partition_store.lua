-- Registry for one partitioned native-save domain.  The objects themselves stay
-- owned by ToME; this module stores only stable identities and ownership.
-- No RPC uses it until partitioned serialization and transactional admission
-- have both been verified.
local M={}
local MAX=9007199254740991
local function integer(v)return type(v)=='number' and v==math.floor(v) and v>0 and v<=MAX end
local function valid_owner(v)return type(v)=='string' and #v>0 and #v<=256 and not v:find('[%z\1-\31]') end
local function classify(value)
 local t=type(value)
 if t=='function' then return 'function' end
 assert(t=='table','native ref requires a table or function')
 local name=rawget(value,'__CLASSNAME')
 if name then
  assert(type(name)=='string' and #name>0 and #name<=256,'invalid native class')
  local uid=rawget(value,'uid')
  if uid~=nil then
   assert(integer(uid),'invalid native entity UID')
   return 'entity',uid,name
  end
  return 'class',nil,name
 end
 return 'table'
end
local function expected_id(value)
 local kind,uid,name=classify(value)
 return kind,uid,name,uid and ('e:'..string.format('%.0f',uid)) or nil
end

function M.new(next_ref)
 next_ref=next_ref or 1;assert(integer(next_ref),'invalid native reference cursor')
 local by_object=setmetatable({},{__mode='k'})
 local live=setmetatable({},{__mode='v'})
 local index={}
 local owners={}
 local store={}
 local function bind(id,value,owner,kind,class_name)
  assert(valid_owner(owner),'invalid partition owner')
  local k,uid,name,expected=expected_id(value)
  assert(kind==k and (not class_name or name==class_name),'native ref type mismatch')
  if expected then assert(id==expected,'native UID/ref mismatch') end
  local existing=index[id]
  if existing then
   assert(existing.owner==owner and existing.kind==kind and existing.class==class_name,'duplicate native ref owner or type')
  else index[id]={owner=owner,kind=kind,class=class_name};owners[owner]=owners[owner] or {};owners[owner][id]=true end
  assert(not live[id] or live[id]==value,'native ref already materialized')
  assert(not by_object[value] or by_object[value]==id,'object has multiple native refs')
  live[id]=value;by_object[value]=id
  return id
 end
 function store:assign(value,owner)
  assert(valid_owner(owner),'invalid partition owner')
  local known=by_object[value]
  if known then return known,index[known].owner end
  local kind,uid,name,id=expected_id(value)
  if not id then
   assert(next_ref<MAX,'native reference cursor exhausted')
   id='r:'..string.format('%.0f',next_ref);next_ref=next_ref+1
  end
  return bind(id,value,owner,kind,name),owner
 end
 function store:pin(value,owner)
  local id,existing=self:assign(value,owner)
  assert(existing==owner,'partition root already owned elsewhere')
  return id
 end
 function store:ref(value)return by_object[value] end
 function store:record_party_class(actor)
  local id=by_object[actor]
  if not id then return end
  local entry=index[id]
  local kind,_,name,expected=expected_id(actor)
  if name==entry.class then return end
  local npc,member='mod.class.NPC','mod.class.PartyMember'
  assert(kind=='entity' and entry.kind==kind and expected==id and entry.owner=='hot' and
         ((entry.class==npc and name==member) or (entry.class==member and name==npc)),
         'unexpected native company class transition')
  entry.class=name
 end
 function store:live(id)return live[id] end
 function store:entry(id)return index[id] end
 function store:live_entries()
  local out={};for id,value in pairs(live)do if value then out[id]=index[id] end end;return out
 end
 function store:cursor()return next_ref end
 function store:bind_loaded(id,value)
  local e=assert(index[id],'unknown external native ref')
  return bind(id,value,e.owner,e.kind,e.class)
 end
 function store:transfer(id,old_owner,new_owner)
  assert(valid_owner(new_owner),'invalid destination owner')
  local e=assert(index[id],'unknown native ref')
  assert(e.owner==old_owner,'native owner mismatch')
  owners[old_owner][id]=nil;owners[new_owner]=owners[new_owner] or {};owners[new_owner][id]=true;e.owner=new_owner
 end
 function store:install_index(entries)
  assert(not next(index),'native ref index already initialized')
  assert(type(entries)=='table','invalid native ref index')
  for id,e in pairs(entries)do
   assert(type(id)=='string' and type(e)=='table' and valid_owner(e.owner),'invalid native ref record')
   assert(e.kind=='entity' or e.kind=='class' or e.kind=='table' or e.kind=='function','invalid native ref kind')
   if e.kind=='entity' then assert(id:match('^e:[1-9]%d*$') and type(e.class)=='string','invalid entity ref')
   else
    local digits=id:match('^r:([1-9]%d*)$');local n=digits and tonumber(digits)
    assert(integer(n) and n<next_ref,'invalid persistent ref')
    if e.kind=='class' then assert(type(e.class)=='string' and #e.class>0,'invalid class ref') else assert(e.class==nil,'unexpected class') end
   end
   index[id]={owner=e.owner,kind=e.kind,class=e.class};owners[e.owner]=owners[e.owner] or {};owners[e.owner][id]=true
  end
 end
 -- Rebase a hot-only commit while keeping live object identities. Cold owner
 -- metadata cannot change or disappear in this restricted path.
 function store:rebase_hot(entries,new_next_ref)
  assert(integer(new_next_ref) and new_next_ref>=next_ref,'invalid rebased reference cursor')
  local checked=M.new(new_next_ref);checked:install_index(entries);local updated=checked:index()
  for id,old in pairs(index)do
   local new=updated[id]
   if old.owner~='hot' then assert(new and new.owner==old.owner and new.kind==old.kind and new.class==old.class,'cold native index changed') end
   if new then assert(new.owner==old.owner and new.kind==old.kind and new.class==old.class,'native ownership changed during hot rebase')
   elseif old.owner=='hot' then local value=live[id];if value then by_object[value]=nil end;live[id]=nil end
  end
  for id,e in pairs(updated)do if not index[id] then assert(e.owner=='hot','new cold native reference')end end
  index=updated;owners={};for id,e in pairs(index)do owners[e.owner]=owners[e.owner] or {};owners[e.owner][id]=true end;next_ref=new_next_ref
 end
 function store:index_owner(owner)
  local out={};for id in pairs(owners[owner] or {})do local e=index[id];out[id]={owner=e.owner,kind=e.kind,class=e.class} end;return out
 end
 function store:rebase_hot_delta(records,retired,new_next_ref,committed)
  assert(type(records)=='table' and type(retired)=='table' and integer(new_next_ref) and new_next_ref>=next_ref,'invalid hot delta')
  assert(type(committed)=='table','missing committed hot index')
  local old=owners.hot or {};local removed={}
  for _,id in ipairs(retired)do assert(type(id)=='string' and committed[id] and old[id] and not records[id] and not removed[id],'invalid retired hot ref');removed[id]=true end
  for id in pairs(committed)do assert(records[id] or removed[id],'hot delta omitted retired ref')end
  for id in pairs(old)do if not records[id] then removed[id]=true end end
  for id,e in pairs(records)do
   assert(type(id)=='string' and type(e)=='table' and e.owner=='hot','invalid hot record')
   local oldentry=index[id]
   assert(oldentry and oldentry.owner=='hot' and oldentry.kind==e.kind and oldentry.class==e.class,'hot record conflicts with registry')
  end
  for id in pairs(removed)do local value=live[id];if value then by_object[value]=nil end;live[id]=nil;index[id]=nil;old[id]=nil end
  owners.hot={};for id in pairs(records)do owners.hot[id]=true end;next_ref=new_next_ref
 end
 function store:index()
  local out={}
  for id,e in pairs(index)do out[id]={owner=e.owner,kind=e.kind,class=e.class} end
  return out
 end
 return store
end
return M
