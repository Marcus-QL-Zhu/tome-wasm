-- Experimental native Savefile transport. NOT exposed as a runtime RPC.
-- Restoring arbitrary Lua bytecode is unsafe; input must be trusted.
local json=require 'json_validate'
local mime=assert(_G.mime,'native MIME module missing')
local M={}
local limit=64*1024*1024
local function encode_chunks(chunks)
 local out=json.object({}); local total=0
 for name,payload in pairs(chunks) do
  assert(type(name)=='string' and type(payload)=='string')
  local encoded=assert(mime.b64(payload,nil)); total=total+#name+#encoded
  assert(total<=limit,'native save exceeds size limit')
  out[name]=encoded
 end
 return out
end
function M.export(root)
 local Savefile=require 'engine.Savefile'
 local previous=Savefile.current_save
 local sf=Savefile.new('headless-native',false)
 local old_emit=native_serial_emit
 local chunks={}; local count,raw_total=0,0
 native_serial_emit=function(name,payload)
  assert(not chunks[name], 'duplicate native object name')
  count=count+1; assert(count<=100000,'native object count limit')
  raw_total=raw_total+#name+#payload;assert(raw_total<=limit,'native raw save exceeds size limit')
  chunks[name]=payload
 end
 core.wait=core.wait or {manualTick=function()end}
 savefile_pipe.current_nb=0
 -- These two closures are installed by this headless host. They carry Lua
 -- upvalues that the original serializer cannot preserve. Rebind after load.
 local filters={}
 local function filter(t,fields)
  if not t then return end
  local original=rawget(t,'_no_save_fields');local inherited=t._no_save_fields;local f={}
  for k,v in pairs(inherited or {})do f[k]=v end
  for _,k in ipairs(fields)do f[k]=true end
  filters[#filters+1]={object=t,original=original};t._no_save_fields=f
 end
 filter(root.game.party,{'setPlayer','__headless_control_bound'})
 local maps,regenerated_meta={},{}
 local function filter_map(map)
  if map and not maps[map] then
   maps[map]=true;require('headless_visuals').assert_snapshot_safe(map);filter(map,{'particleEmitter'})
   for _,k in ipairs({'attrs','has_seens','infovs','lites','remembers','seens'}) do
    if type(map[k])=='table' then regenerated_meta[map[k]]=true end
   end
  end
 end
 if root.game.level then filter_map(root.game.level.map) end
 local application=root.application or {}
 local app=application.state or application
 local zones={}
 local function filter_zone(zone)
  if zone and not zones[zone] then
   assert(not zone.on_loaded,'native Zone on_loaded lifecycle not yet supported')
   zones[zone]=true
   if zone._project_reference_level then
    assert(require('native_zone').is_bound_zone(zone),'unrecognized native zone closures')
    filter(zone,{'actor_adjust_level','post_filter'})
    -- Original disk saves omit these native lists and reload from zone files.
    -- A fresh VM must preserve their real objects/UIDs without rerunning the
    -- generator during Entity restore mode.
    for _,key in ipairs({'npc_list','grid_list','object_list','trap_list'}) do zone._no_save_fields[key]=nil end
   end
   if zone.short_name=='formal-squad' then
    assert(require('formal_factory').is_bound_formal_lists(zone),'unrecognized formal zone closure')
    filter(zone,{'embed_lists'})
   end
  end
 end
 filter_zone(root.game.zone)
 for _,area in pairs(app._dm_local_areas or {})do
  filter_zone(area.zone)
  for _,slot in pairs(area.floors or {})do if slot.level then filter_map(slot.level.map) end end
 end
 -- Preserve identity for every ordinary native table, including tables used
 -- as keys. Object class saving and hooks still use original class.save.
 local names,weak_modes={},{};local next_table=0;local native_name=sf.getFileName
 sf.getFileName=function(self,t)
  if rawget(t,'__CLASSNAME') then return native_name(self,t) end
  if not names[t] then next_table=next_table+1;names[t]='native_table_'..next_table end
  return names[t]
 end
 sf.current_save_main=root;sf.current_save_zip='memory'
 local old_plain=native_serial_plain_reference
 local old_classify=native_serial_classify_function
 local function_writer=require('native_function_env').new_writer()
 local function_ids={};local next_function=0
 native_serial_classify_function=function(fn)
  local id=function_ids[fn];if not id then next_function=next_function+1;id=next_function;function_ids[fn]=id end
  assert(id<=100000,'native function count limit')
  return function_writer:classify(fn),id
 end
 native_serial_plain_reference=true
 local ok,err=xpcall(function()
  sf:addToProcess(root)
  local processed=0
  while #sf.process>0 do
   local t=table.remove(sf.process);sf.tables[t]=sf:getFileName(t)
   processed=processed+1;assert(processed<=100000,'native fragment count limit')
   if rawget(t,'__CLASSNAME') then
    if t.__CLASSNAME=='engine.Level' then assert(not t.last_iteration,'native level scheduler is mid-iteration') end
    if t.onSaving then
     assert(t.__CLASSNAME=='engine.Level' and t.onSaving==require('engine.Level').onSaving,'unclassified native onSaving hook')
     t:onSaving()
    end
    t:save()
   else
    local mt=getmetatable(t)
    if mt and not regenerated_meta[t] then
     assert(type(mt)=='table','protected native table metatable unsupported')
     local visual=require('headless_visuals').snapshot_metatype(t)
     local mode=rawget(mt,'__mode')
     if visual then weak_modes[sf:getFileName(t)]=visual else
     for k in pairs(mt) do assert(k=='__mode','unsupported native table metatable '..tostring(k)) end
     if mode then
      assert(mode=='k' or mode=='v' or mode=='kv' or mode=='vk','unsupported native weak mode')
      weak_modes[sf:getFileName(t)]=mode
     end
     end
    end
    local serializer=core.serial.new('memory',function(v)return sf:getFileName(v) end,function(v)sf:addToProcess(v)end,nil,nil,nil)
    serializer:toZip(t)
   end
  end
 end,debug.traceback)
 native_serial_plain_reference=old_plain
 native_serial_classify_function=old_classify
 for _,entry in ipairs(filters)do entry.object._no_save_fields=entry.original end
 native_serial_emit=old_emit; Savefile.current_save=previous
 if not ok then error(err) end
 assert(chunks.main and count>0, 'empty native save')
 chunks.native_meta_modes=json.encode(json.object(weak_modes))
 chunks.native_meta_functions=json.encode(function_writer:manifest())
 return encode_chunks(chunks),count
end
-- Strict equivalent of the original Savefile self-reference resolver.
local function resolve_self(o,base,allow_object,seen)
 if (o.__ATOMIC or o.__CLASSNAME) and not allow_object then return end
 seen=seen or {};if seen[o] then return end;seen[o]=true
 local changes={}
 for k,e in pairs(o) do
  if type(e)=='table' then
   if e==class.LOAD_SELF then changes[#changes+1]=k else resolve_self(e,base,false,seen) end
  end
 end
 for _,k in ipairs(changes) do o[k]=base end
end

-- Experimental internal reader, available only to isolated diagnostics.
-- The caller must supply authenticated same-build chunks, and discard the
-- entire VM on any error. This is not a public import endpoint.
function M.read(chunks,next_uid,shell,zone_config)
 local Savefile=require 'engine.Savefile'
 local sf=Savefile.new('headless-native-import',false)
 local count,total=0,0
 for name,value in pairs(chunks) do
  assert(type(name)=='string' and type(value)=='string','bad native chunk')
  count=count+1;total=total+#name+#value
  assert(count<=100000 and total<=limit,'native chunk limit')
 end
 assert(count>0 and chunks.main and chunks.native_meta_modes and chunks.native_meta_functions,'missing native root')
 local manifest_json=assert(mime.unb64(chunks.native_meta_functions,nil),'bad function metadata')
 local manifest=assert(json.decode(manifest_json),'invalid function metadata')
 local function_reader=require('native_function_env').new_reader(manifest)
 local loaded_functions={}
 sf.loadFunction=function(_,code,id,fnid)
  assert(type(fnid)=='number' and fnid==math.floor(fnid) and fnid>=1 and fnid<=100000,'invalid native function id')
  if loaded_functions[fnid] then
   assert(loaded_functions[fnid].code==code and loaded_functions[fnid].env==id,'conflicting native function id')
   return loaded_functions[fnid].value
  end
  local fn,err=loadstring(code);assert(fn,'invalid native function: '..tostring(err))
  fn=function_reader:bind(fn,id);loaded_functions[fnid]={code=code,env=id,value=fn}
  return fn
 end
 local encoded_modes=assert(mime.unb64(chunks.native_meta_modes,nil),'bad native metadata')
 local modes=assert(json.decode(encoded_modes),'bad native weak metadata')
 assert(json.isobject(modes),'invalid native weak metadata')
 sf.loadPlain=function(self,name)
  if self.loaded[name] then return self.loaded[name] end
  assert(type(name)=='string' and name:match('^native_table_%d+$'),'invalid plain native fragment name')
  local encoded=assert(chunks[name],'missing native table '..name)
  local data=assert(mime.unb64(encoded,nil),'bad base64 native table')
  local f,err=loadstring(data);assert(f,'invalid native table '..name..': '..tostring(err))
  setfenv(f,{
   setLoaded=function(n,t) assert(n==name and not self.loaded[n],'duplicate native table');self.loaded[n]=t end,
   loadstring=loadstring,
   loadFunction=function(code,id,fnid)return self:loadFunction(code,id,fnid)end,
   loadTable=function(n)return self:loadPlain(n)end,
   loadObject=function(n)return self:loadReal(n)end,
  })
  local value=assert(f());assert(value==self.loaded[name],'invalid native table root')
  local mode=modes[name];if mode=='visual' or mode=='visual_backend' then require('headless_visuals').restore_metatype(value,mode) elseif mode then assert(mode=='k' or mode=='v' or mode=='kv' or mode=='vk','invalid weak mode');setmetatable(value,{__mode=mode}) end
  return value
 end
 sf.loadReal=function(self,name)
  if self.loaded[name] then return self.loaded[name] end
  local encoded=assert(chunks[name],'missing native object '..tostring(name))
  local data=assert(mime.unb64(encoded,nil),'bad base64 native object')
  local fn,syntax_error=loadstring(data);assert(fn,'invalid native object '..name..': '..tostring(syntax_error))
  local object=assert(class.load(data,name),'native object load failed '..name)
  resolve_self(object,object,true)
  self.loaded[name]=object
  return object
 end
 require('formal_factory').install_object_resolver()
 local Entity=require 'engine.Entity'
 Entity.native_uid_begin_restore()
 local root=assert(sf:loadReal('main'))
 local restored=assert(root.game)
 for _,key in ipairs({'dialogs','__coroutines','nicer_tiles','uiset','target','flyers','log','logNewest','logRollback','playSound','playSoundNear','can_pause','calendar','__mod_info','delayed_log_messages','delayed_log_damage','tiles_attachements','tiles_facing','bignews'}) do
  if rawget(restored,key)==nil then rawset(restored,key,rawget(shell,key)) end
 end
 -- Game:save persists accumulated play time but not the session timestamp.
 -- Match native runReal: this VM starts a new wall-clock session.
 assert(type(shell.real_starttime)=='number','missing native session clock')
 restored.real_starttime=shell.real_starttime;restored.last_update=nil
 _G.game=restored;_G.world=assert(root.world)
 local Zone=require 'mod.class.Zone'
 Zone:setup{npc_class='mod.class.NPC',grid_class='mod.class.Grid',object_class='mod.class.Object',trap_class='mod.class.Trap',on_setup=function(z) game:applyDifficulty(z) end}
 Zone.check_filter=function(...) return game.state:entityFilter(...) end
 Zone.default_prob_filter=true
 Zone.default_filter=function(...) return game.state:defaultEntityFilter(...) end
 Zone.alter_filter=function(...) return game.state:entityFilterAlter(...) end
 Zone.post_filter=function(...) return game.state:entityFilterPost(...) end
 Zone.ego_filter=function(...) return game.state:egoFilter(...) end
 for _,o in ipairs(sf.delayLoad) do
  if o==restored then
   assert(not (o.zone and o.zone.on_loaded),'native Game zone on_loaded lifecycle not yet supported')
   -- Preserve the original energy scheduler's reindexing and weak values,
   -- while excluding the original desktop-only engine.Game.loaded UI path.
   local base=require 'engine.Game';local original=base.loaded
   base.loaded=function(g) g.__coroutines=g.__coroutines or {};g.dialogs={} end
   local ok,err=xpcall(function() require('engine.GameEnergyBased').loaded(o) end,debug.traceback)
   base.loaded=original;if not ok then error(err) end
  else
   if o.__CLASSNAME=='mod.class.Zone' and o._project_reference_level then require('native_zone').bind_zone(o) end
   if o.__CLASSNAME=='mod.class.Zone' and o.short_name=='formal-squad' then require('formal_factory').bind_formal_lists(o,zone_config) end
   if o.__CLASSNAME=='mod.class.Zone' then
    assert(o.npc_list and o.grid_list and o.object_list and o.trap_list,'native zone lists missing; refusing regeneration during restore')
    local reload=o.reload_lists;o.reload_lists=false;o:loaded();o.reload_lists=reload
   else o:loaded() end
  end
 end
 Entity.native_uid_end_restore(next_uid)
 return root
end

return M

