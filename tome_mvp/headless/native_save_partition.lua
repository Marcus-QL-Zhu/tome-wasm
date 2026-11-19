-- Experimental native object partitions. Raw native Savefile fragments remain
-- opaque; this module does not project actor, map, or item fields to JSON.
-- Nontrivial table metatables remain refused until their native lifecycle is verified.
local Registry=require 'native_partition_store'
local M={}
local function owner_id(id)assert(type(id)=='string' and #id>0 and #id<=256,'invalid owner');return id end
local function resolve_self(o,base,allow,seen)
 if (o.__ATOMIC or o.__CLASSNAME) and not allow then return end
 seen=seen or {};if seen[o] then return end;seen[o]=true
 local keys={}
 for k,v in pairs(o)do
  if type(v)=='table' then
   if v==class.LOAD_SELF then keys[#keys+1]=k else resolve_self(v,base,false,seen) end
  end
 end
 for _,k in ipairs(keys)do o[k]=base end
end

-- Roots must be pinned up front, so traversing an earlier root never absorbs a
-- later partition root. Caller provides deterministic ordered owner roots.
function M.export(roots,registry,existing_writer,options)
 options=options or {}
 assert(type(roots)=='table' and #roots>0,'partition roots required')
 registry=registry or Registry.new()
 local seen={}
 for _,r in ipairs(roots)do
  owner_id(r.owner);assert(not seen[r.owner] and type(r.root)=='table','invalid partition root');seen[r.owner]=true
  r.root_ref=registry:pin(r.root,r.owner)
 end
 local S=require 'engine.Savefile';local previous=S.current_save
 local old_emit,old_plain,old_classifier=native_serial_emit,native_serial_plain_reference,native_serial_classify_function
 local old_function_ref,old_filter=native_serial_partition_function_reference,native_serial_filter_entry
 local parts,contexts={},{};local writer=existing_writer or require('native_function_env').new_writer()
 local filters,regenerated_meta,cursor_restore={},{},{}
 local function filter(t,fields,unfilter)
  local original=rawget(t,'_no_save_fields');local f={}
  for k,v in pairs(t._no_save_fields or {})do f[k]=v end
  for _,k in ipairs(fields or {})do f[k]=true end
  for _,k in ipairs(unfilter or {})do f[k]=nil end
  filters[#filters+1]={object=t,original=original};t._no_save_fields=f
 end
 for _,map in ipairs(options.maps or {})do
  require('headless_visuals').assert_snapshot_safe(map)
  for _,k in ipairs({'attrs','has_seens','infovs','lites','remembers','seens'})do
   if type(map[k])=='table' then regenerated_meta[map[k]]=true end
  end
 end
 native_serial_plain_reference=true;native_serial_partition_function_reference=true
 local function collectible(v)return type(v)=='table' or type(v)=='function' end
 local function desc(v)
  if collectible(v) then local id=registry:ref(v);if not id then return nil end;return {ref=id} end
  local t=type(v);assert(t=='boolean' or t=='number' or t=='string','unsupported weak table value')
  if t=='number' then assert(v==v and v~=math.huge and v~=-math.huge,'nonfinite weak value') end
  return {value=v}
 end
 local ok,err=xpcall(function()
  for _,r in ipairs(roots)do
   local sf=S.new('partition',false);local c={sf=sf,owner=r.owner,root=r.root,chunks={},strong={},functions={},modes={},anchors={},pending={},weak_edges={},count=0}
   contexts[#contexts+1]=c
   sf.getFileName=function(_,o)local id=registry:assign(o,c.owner);return id end
   sf.addToProcess=function(self,o)
    local id,owner=registry:assign(o,c.owner)
    if owner~=c.owner then c.strong[id]=true;return end
    if not self.tables[o] then self.tables[o]=true;self.process[#self.process+1]=o end
   end
   sf.current_save_main=r.root;sf.current_save_zip='memory';sf:addToProcess(r.root)
   parts[c.owner]={root_ref=r.root_ref,fragments=c.chunks,functions=c.functions,strong_refs=c.strong,modes=c.modes,anchors=c.anchors,weak_edges=c.weak_edges}
  end
  local function run(c)
   local sf,current=c.sf,c.owner;S.current_save=sf
   native_serial_emit=function(name,payload)assert(not c.chunks[name],'duplicate partition fragment');c.chunks[name]=payload end
   native_serial_classify_function=function(fn)
    local ref,owner=registry:assign(fn,current);local number=assert(tonumber(ref:match('^r:(%d+)$')),'invalid native function ref')
    local kind,key,path,witness;if native_catalog_anchor_enabled then kind,key,path,witness=require('native_catalog_anchor').identify(fn) end
    local env=kind and 0 or writer:classify(fn)
    if owner==current then if not c.functions[ref] then c.functions[ref]={code=kind and '' or string.dump(fn),env=env,anchor=kind and {kind=kind,key=key,path=path,witness=witness} or nil} end else c.strong[ref]=true end
    return env,number
   end
   native_serial_filter_entry=function(t,k,v)
    if options.inspect_edge then options.inspect_edge(t,k,v,registry,c.owner) end
    local mode=c.modes[registry:ref(t)]
    if mode~='k' and mode~='v' and mode~='kv' and mode~='vk' then return false end
    local wk=mode:find('k',1,true) and collectible(k)
    local wv=mode:find('v',1,true) and collectible(v)
    if not wk and not wv then return false end
    c.pending[#c.pending+1]={parent=registry:ref(t),key=k,value=v,wk=not not wk,wv=not not wv}
    if not wk and collectible(k) then if type(k)=='table' then sf:addToProcess(k) else native_serial_classify_function(k) end end
    return true
   end
   while #sf.process>0 do
    local o=table.remove(sf.process);sf.tables[o]=sf:getFileName(o);c.count=c.count+1
    assert(c.count<=100000,'partition object count limit')
    local kind,key,path,witness;if native_catalog_anchor_enabled then kind,key,path,witness=require('native_catalog_anchor').identify(o) end
    if kind then c.anchors[sf.tables[o]]={kind=kind,key=key,path=path,witness=witness};c.chunks[sf.tables[o]]=''
    elseif rawget(o,'__CLASSNAME') then
     local cname=o.__CLASSNAME
     if cname=='mod.class.Party' then filter(o,{'setPlayer','__headless_control_bound'}) end
     if cname=='engine.Map' then
      require('headless_visuals').assert_snapshot_safe(o);filter(o,{'particleEmitter'})
      for _,k in ipairs({'attrs','has_seens','infovs','lites','remembers','seens'})do if type(o[k])=='table' then regenerated_meta[o[k]]=true end end
     end
     if cname=='mod.class.Zone' then
      assert(not o.on_loaded,'native Zone on_loaded lifecycle not yet supported')
      if o._project_reference_level then
       assert(require('native_zone').is_bound_zone(o),'unrecognized native zone closures')
       filter(o,{'actor_adjust_level','post_filter'},{'npc_list','grid_list','object_list','trap_list'})
      end
      if o.short_name=='formal-squad' then
       assert(require('formal_factory').is_bound_formal_lists(o),'unrecognized formal zone closure');filter(o,{'embed_lists'})
      end
      -- The native Zone saver omits these definitions to rebuild them at load.
      -- Retain the existing objects so checkpoint restore allocates no new UIDs.
      if require('native_zone').is_temporary(o) then
       assert(not o.embed_lists,'unexpected temporary Zone lists')
       filter(o,{}, {'npc_list','grid_list','object_list','trap_list'})
      end
     end
     local cursor
     if cname=='engine.Level' and o._native_parked_cursor and o._native_parked_cursor~=o.last_iteration then o._native_parked_cursor=nil end
     if cname=='engine.Level' and o.last_iteration then
      cursor=o.last_iteration
      local parked=rawget(o,'_native_parked_cursor')==cursor
      assert(game and (game.paused or (parked and options.allow_parked_cursor)) and (parked or game.level==o) and not rawget(o,'_native_partition_cursor'),'native level scheduler is mid-iteration')
      assert(type(cursor)=='table' and type(cursor.i)=='number' and cursor.i==math.floor(cursor.i) and cursor.i>=(parked and 0 or 1) and cursor.i<=#o.e_array and cursor.e and cursor.e.__CLASSNAME and cursor.e.uid and (parked or o.e_array[cursor.i]==cursor.e),'invalid native scheduler cursor')
      for key in pairs(cursor)do assert(key=='i' or key=='e','unknown native scheduler cursor state')end
      cursor_restore[#cursor_restore+1]={level=o,cursor=cursor}
      o._native_partition_cursor=cursor
     end
     if o.onSaving then
      assert(cname=='engine.Level' and o.onSaving==require('engine.Level').onSaving,'unclassified native onSaving hook');o:onSaving()
     end
     o:save()
     if cursor then o.last_iteration=cursor;o._native_partition_cursor=nil end
    else
     local mt=getmetatable(o)
     if mt and not regenerated_meta[o] then
      assert(type(mt)=='table','protected table metatable unsupported')
      local visual=require('headless_visuals').snapshot_metatype(o)
      local json=require 'json_validate'
      if visual then c.modes[registry:ref(o)]=visual
      elseif json.isobject(o) then c.modes[registry:ref(o)]='json_object'
      elseif json.isarray(o) then c.modes[registry:ref(o)]='json_array'
      else
       local mode=rawget(mt,'__mode')
       for k in pairs(mt)do assert(k=='__mode','unsupported native partition metatable '..tostring(k))end
       assert(mode=='k' or mode=='v' or mode=='kv' or mode=='vk','unsupported native weak mode')
       c.modes[registry:ref(o)]=mode
      end
     end
     local serializer=core.serial.new('memory',function(v)return sf:getFileName(v)end,function(v)sf:addToProcess(v)end,nil,nil,nil)
     serializer:toZip(o)
    end
   end
  end
  for _,c in ipairs(contexts)do run(c)end
  -- Strong values of weak-key entries are reachable only if their key is
  -- independently strongly reachable. Iterate until no new strong work exists.
  local changed=true
  while changed do
   changed=false
   for _,c in ipairs(contexts)do
    S.current_save=c.sf
    for _,e in ipairs(c.pending)do
     if not e.resolved and (not e.wk or registry:ref(e.key)) then
      e.resolved=true
      if not e.wv and collectible(e.value) then
       if type(e.value)=='table' then c.sf:addToProcess(e.value)
       else
        -- Set per-owner callbacks before classifying the strong function.
        run(c);native_serial_classify_function(e.value)
       end
      end
      changed=true
     end
    end
    if #c.sf.process>0 then run(c);changed=true end
   end
   -- Keep real bodies for cross-owner references, including references from
   -- trusted unchanged partitions. A formerly hot object may now be reached
   -- only by a dirty cold root, and must not silently disappear.
   local needed={}
   for _,ref in ipairs(options.required_refs or {})do needed[ref]=true end
   for _,other in ipairs(contexts)do for ref in pairs(other.strong)do needed[ref]=true end end
   for ref in pairs(needed)do
    local entry=assert(registry:entry(ref),'unknown required native ref')
    for _,c in ipairs(contexts)do if entry.owner==c.owner and not c.chunks[ref] and not c.functions[ref] then
     local value=registry:live(ref)
     if not value and options.resolve_required then value=options.resolve_required(ref,entry) end
     value=assert(value,'required native object not resident')
     if entry.kind=='function' then run(c);native_serial_classify_function(value)
     else c.sf:addToProcess(value);run(c) end
     assert(c.chunks[ref] or c.functions[ref],'required native body not emitted')
     changed=true
    end end
   end
  end
  for _,c in ipairs(contexts)do
   if native_catalog_anchor_enabled then parts[c.owner].orders=require('native_zone_order').export(c.owner,c.chunks) end
   for _,e in ipairs(c.pending)do
    local k,v=desc(e.key),desc(e.value)
    if k and v and (not e.wk or e.resolved) then c.weak_edges[#c.weak_edges+1]={parent=e.parent,key=k,value=v,key_weak=e.wk,value_weak=e.wv} end
   end
  end
 end,debug.traceback)
 for _,f in ipairs(filters)do f.object._no_save_fields=f.original end
 for _,c in ipairs(cursor_restore)do c.level.last_iteration=c.cursor;c.level._native_partition_cursor=nil end
 native_serial_emit=old_emit;native_serial_plain_reference=old_plain;native_serial_classify_function=old_classifier;native_serial_partition_function_reference=old_function_ref;native_serial_filter_entry=old_filter;S.current_save=previous
 if not ok then error(err) end
 return {parts=parts,index=options.index_owner and registry:index_owner(options.index_owner) or registry:index(),next_ref=registry:cursor(),function_env=writer:manifest()},registry
end

-- `provide` returns a trusted fragment by its owner and ref; absent owners fail
-- rather than silently substituting another object. This phase binds objects
-- before filling them, preserving ordinary cycles, table keys and class aliases.
function M.reader(index,next_ref,provide,function_env,provide_function,provide_metadata,existing_registry)
 assert(type(provide)=='function','partition provider required')
 local registry=existing_registry or Registry.new(next_ref);if not existing_registry then registry:install_index(index) end
 local S=require 'engine.Savefile';local sf=S.new('partition-reader',false)
 local order;if native_catalog_anchor_enabled then order=require('native_zone_order');native_zone_order_pairs=order.pairs end
 sf.loaded=setmetatable({},{__mode='v'})
 local read_count={};local pending={}
 local function_reader=function_env and require('native_function_env').new_reader(function_env)
 local function get_function(number)
  assert(type(number)=='number' and number==math.floor(number) and number>0,'invalid native function reference')
  local ref='r:'..string.format('%.0f',number);local entry=assert(registry:entry(ref),'missing native function')
  assert(entry.kind=='function','native function ref type mismatch')
  local live=registry:live(ref);if live then return live end
  assert(function_reader and type(provide_function)=='function','native function provider missing')
  local definition=assert(provide_function(entry.owner,ref),'missing native function body')
  local fn
  if definition.anchor then local a=definition.anchor;fn=require('native_catalog_anchor').resolve(a.kind,a.key,a.path,a.witness)
  else local why;fn,why=loadstring(definition.code);assert(fn,'invalid native function body: '..tostring(why));fn=function_reader:bind(fn,definition.env) end
  registry:bind_loaded(ref,fn);return fn
 end
 sf.loadFunctionRef=function(_,id)return get_function(id)end
 local get
 get=function(ref,expected)
  local entry=assert(registry:entry(ref),'missing native ref')
  if expected=='table' then assert(entry.kind=='table','native table ref type mismatch')
  else assert(entry.kind=='class' or entry.kind=='entity','native class ref type mismatch') end
  local live=registry:live(ref) or sf.loaded[ref];if live then return live end
  local meta=provide_metadata and assert(provide_metadata(entry.owner),'missing partition metadata')
  local anchor=meta and meta.anchors and meta.anchors[ref]
  if anchor then
   assert(native_catalog_anchor_enabled,'catalog anchors disabled')
   local value=require('native_catalog_anchor').resolve(anchor.kind,anchor.key,anchor.path,anchor.witness)
   registry:bind_loaded(ref,value);sf.loaded[ref]=value;return value
  end
  local payload=assert(provide(entry.owner,ref),'missing native fragment')
  read_count[entry.owner]=(read_count[entry.owner] or 0)+1
  local fn,why=loadstring(payload);assert(fn,'invalid native fragment: '..tostring(why))
  local obj
  local env={
   setLoaded=function(id,t)
    assert(id==ref and not obj,'invalid native fragment identity')
    obj=t
    if order then order.begin(id,entry.owner,t) end
    if expected=='table' then registry:bind_loaded(id,t) end
    sf.loaded[id]=t
   end,
   loadstring=loadstring,
   loadFunctionRef=function(id)return get_function(id)end,
   loadTable=function(id)return get(id,'table')end,
   loadObject=function(id)return get(id,'class')end,
  }
  if expected=='table' then
   setfenv(fn,env);local out=fn();assert(out==obj,'invalid native table fragment')
   if order then order.finish(obj,meta and meta.orders and meta.orders[ref]) end
   if provide_metadata then
    local metadata=assert(provide_metadata(entry.owner),'missing partition metadata')
    local mode=metadata.modes and metadata.modes[ref]
    if mode then
     if order and (mode=='k' or mode=='v' or mode=='kv' or mode=='vk') then order.discard(obj) end
     if mode=='visual' or mode=='visual_backend' then require('headless_visuals').restore_metatype(obj,mode)
     elseif mode=='json_object' then require('json_validate').object(obj)
     elseif mode=='json_array' then require('json_validate').array(obj)
     else assert(mode=='k' or mode=='v' or mode=='kv' or mode=='vk','invalid weak mode');setmetatable(obj,{__mode=mode}) end
     for _,edge in ipairs(metadata.weak_edges or {})do if edge.parent==ref then
      pending[#pending+1]={owner=setmetatable({obj},{__mode='v'}),edge=edge,partition_owner=entry.owner}
     end end
    end
   end
  else
   -- Original class.load establishes the metatable and native loaded hooks.
   -- Its environment delegates references to this shared reader.
   sf.loadReal=function(_,id)return get(id,'class')end
   sf.loadPlain=function(_,id)return get(id,'table')end
   local old_capture=native_zone_order_capture
   if order then native_zone_order_capture=function(id,t)local e=assert(registry:entry(id));order.begin(id,e.owner,t)end end
   local ok,out=xpcall(function()return assert(class.load(payload,ref),'native class load failed')end,debug.traceback)
   native_zone_order_capture=old_capture;if not ok then error(out)end
   if order then order.finish(out,meta and meta.orders and meta.orders[ref]) end
   obj=out;resolve_self(obj,obj,true);registry:bind_loaded(ref,obj)
  end
  return obj
 end
 function sf:loadReal(ref)return get(ref,'class')end
 function sf:loadPlain(ref)return get(ref,'table')end
 local reader={}
 local function resolve_desc(d,weak)
  assert(type(d)=='table','invalid weak reference descriptor')
  if d.ref then
   local live=registry:live(d.ref) or sf.loaded[d.ref]
   if live or weak then return live end
   local e=assert(registry:entry(d.ref),'missing strong reference')
   if e.kind=='function' then return get_function(assert(tonumber(d.ref:match('^r:(%d+)$')))) end
   return get(d.ref,e.kind=='table' and 'table' or 'class')
  end
  return d.value
 end
 local function patch_weak()
  local again=true;local rounds=0
  while again do
   rounds=rounds+1;assert(rounds<=100000,'weak reference fixup limit');again=false
   for i=#pending,1,-1 do
    local p=pending[i];local owner=p.owner[1]
    if not owner then table.remove(pending,i)
    else
     local key=resolve_desc(p.edge.key,p.edge.key_weak)
     if key~=nil then
      local value=resolve_desc(p.edge.value,p.edge.value_weak)
      if value~=nil and rawget(owner,key)~=value then rawset(owner,key,value);again=true end
     end
    end
   end
  end
 end
 function reader:load(ref,options)
  options=options or {};S.current_save=sf
  local entity=options.native and require('engine.Entity') or nil
  local before_rng=options.native and rng.state_get() or nil
  if entity then entity.native_uid_begin_restore() end
  local e=assert(registry:entry(ref),'unknown root ref')
  local v=get(ref,e.kind=='table' and 'table' or 'class')
  if options.on_root then options.on_root(v) end
  patch_weak()
  if entity then
   for _,o in ipairs(sf.delayLoad)do
    if o.__CLASSNAME=='mod.class.Game' then
     assert(type(options.on_game_loaded)=='function','headless Game lifecycle adapter required')
     options.on_game_loaded(o)
    elseif o.__CLASSNAME=='mod.class.Zone' then
     if o._project_reference_level then require('native_zone').bind_zone(o) end
     if o.short_name=='formal-squad' then require('formal_factory').bind_formal_lists(o,options.zone_config) end
     assert(not o.on_loaded and o.npc_list and o.grid_list and o.object_list and o.trap_list,'unsupported native zone load')
     local flag=o.reload_lists;o.reload_lists=false;o:loaded();o.reload_lists=flag
    else o:loaded() end
    if o.__CLASSNAME=='engine.Level' and o._native_partition_cursor then
     local c=o._native_partition_cursor;local parked=o._native_parked_cursor==c;assert(type(c)=='table' and type(c.i)=='number' and c.i==math.floor(c.i) and c.i>=(parked and 0 or 1) and c.i<=#o.e_array and c.e and c.e.__CLASSNAME and c.e.uid and (parked or o.e_array[c.i]==c.e),'invalid restored native scheduler cursor');o.last_iteration=c;o._native_partition_cursor=nil
    end
   end
   sf.delayLoad={};entity.native_uid_end_restore(assert(options.next_uid,'native UID cursor required'))
   local after=rng.state_get()
   assert(after.format==before_rng.format and after.index==before_rng.index and after.stored==before_rng.stored and after.normal_spare==before_rng.normal_spare,'native partition load changed RNG')
   for i=1,624 do assert(after.words[i]==before_rng.words[i],'native partition load changed RNG words') end
   patch_weak()
  end
  return v
 end
 function reader:resolve(ref,options)
  local e=assert(registry:entry(ref),'unknown native ref')
  if e.kind=='function' then return get_function(assert(tonumber(ref:match('^r:(%d+)$')))) end
  return self:load(ref,options)
 end
 local function rebase_hot_finish(hot)
  for id in pairs(sf.loaded)do if not registry:entry(id) then sf.loaded[id]=nil end end
  for i=#pending,1,-1 do if pending[i].partition_owner=='hot' then table.remove(pending,i)end end
  for _,edge in ipairs(hot.weak_edges)do
   local owner=registry:live(edge.parent)
   if owner then pending[#pending+1]={owner=setmetatable({owner},{__mode='v'}),edge=edge,partition_owner='hot'} end
  end
 end
 function reader:rebase_hot(index,next_ref,hot,writer)
  assert(type(hot)=='table' and hot.owner=='hot' and type(hot.weak_edges)=='table','invalid committed hot partition')
  assert(function_reader and hot.function_env,'missing committed function environments')
  function_reader:rebase(hot.function_env,writer);registry:rebase_hot(index,next_ref);rebase_hot_finish(hot)
 end
 function reader:rebase_hot_delta(delta,next_ref,hot,writer,committed)
  assert(type(hot)=='table' and hot.owner=='hot' and type(hot.weak_edges)=='table' and type(delta)=='table' and delta.format=='tome-hot-index-delta-v1' and delta.owner=='hot','invalid committed hot delta')
  assert(function_reader and hot.function_env,'missing committed function environments')
  function_reader:rebase(hot.function_env,writer);registry:rebase_hot_delta(delta.records,delta.retired,next_ref,committed);rebase_hot_finish(hot)
 end
 function reader:refresh_weak()patch_weak()end
 function reader:release(owner)
  for id in pairs(sf.loaded)do local e=registry:entry(id);if e and e.owner==owner then sf.loaded[id]=nil end end
 end
 function reader:registry()return registry end
 function reader:function_writer()assert(function_reader,'missing function environment');return function_reader:writer() end
 function reader:reads(owner)return read_count[owner] or 0 end
 return reader
end
return M
