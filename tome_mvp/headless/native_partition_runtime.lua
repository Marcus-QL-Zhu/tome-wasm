-- Host-owned transactional transport of native partition fragments.
-- The caller authenticates manifests and verifies blob digests before use.
local json=require 'json_validate'
local bundle=require 'native_save_bundle'
local partition=require 'native_save_partition'
local scene=require 'native_save_partition_scene'
local M={ready=false,warm_ready=false}

function M.export(state,runtime,registry,writer,protected_by_owner,reader,hot_delta,committed_hot,retain_hot_provider)
 local dirty={hot=true}
 for id,area in pairs(state._dm_local_areas or {})do
  if area.zone then dirty[scene.zone_owner(id)]=true end
  for floor,slot in pairs(area.floors)do if slot.level then dirty[scene.floor_owner(id,floor)]=true end end
 end
 local protected_refs={}
 for owner,refs in pairs(protected_by_owner or {})do
  assert(type(owner)=='string' and type(refs)=='table','invalid protected owner')
  if not dirty[owner]then for _,ref in ipairs(refs)do assert(type(ref)=='string');local e=registry and assert(registry:entry(ref),'unknown protected native ref');if not hot_delta or e.owner=='hot' then protected_refs[#protected_refs+1]=ref end end end
 end
 local data,r,plan=scene.capture(state,runtime,registry,writer,{protected_refs=protected_refs,resolve_required=reader and function(ref)return reader:resolve(ref,{native=true,next_uid=require('engine.Entity').native_uid_state()})end,index_owner=hot_delta and 'hot' or nil})
 for owner in pairs(dirty)do assert(data.parts[owner],'planned dirty owner not emitted')end
 for owner in pairs(data.parts)do assert(dirty[owner],'unplanned dirty owner emitted');if hot_delta then assert(owner=='hot','hot delta changed cold owner') end end
 local incoming={};for _,ref in ipairs(protected_refs)do incoming[ref]=true end
 local expected={hot=true}
 for _,area in pairs(plan.catalog)do expected[area.zone_owner]=true;for _,slot in pairs(area.floors)do expected[slot.owner]=true end end
 for owner in pairs(expected)do assert(data.parts[owner] or protected_by_owner,'prior committed references required for cold partitions')end
 local bodies={}
 for _,part in pairs(data.parts)do
  for ref in pairs(part.fragments)do bodies[ref]=true end
  for ref in pairs(part.functions)do bodies[ref]=true end
  for ref in pairs(part.strong_refs)do incoming[ref]=true end
 end
 for ref,entry in pairs(data.index)do if data.parts[entry.owner] and not bodies[ref]then
  assert(not incoming[ref],'dirty owner omitted strongly referenced native fragment')
  data.index[ref]=nil
 end end
 for _,part in pairs(data.parts)do
  local kept={};for _,edge in ipairs(part.weak_edges)do
   local function exists(ref)if not ref then return true end;if data.index[ref] then return true end;local e=hot_delta and registry:entry(ref);return e and e.owner~='hot' end
   if exists(edge.key.ref) and exists(edge.value.ref)then kept[#kept+1]=edge end
  end;part.weak_edges=kept
  for ref in pairs(part.strong_refs)do assert(data.index[ref],hot_delta and 'hot delta requires cold owner' or 'missing strong native reference')end
 end
 local payloads=json.array();local descriptors=json.array();local hot_provider
 local metadata={hot={kind='hot'}}
 for id,area in pairs(plan.catalog)do
  metadata[area.zone_owner]={kind='zone',area_id=id}
  for floor,slot in pairs(area.floors)do metadata[slot.owner]={kind='level',area_id=id,floor=floor} end
 end
 for owner,part in pairs(data.parts)do
  local p,provider=bundle.encode(owner,part,owner=='hot' and data.function_env or nil,owner=='hot' and retain_hot_provider)
  if provider then assert(not hot_provider);hot_provider=provider end
  payloads[#payloads+1]=json.object(p)
  local info=assert(metadata[owner],'missing native partition descriptor')
  descriptors[#descriptors+1]=json.object({partition_id=owner,kind=info.kind,area_id=info.area_id,floor=info.floor,root_ref=p.root_ref,strong_refs=p.strong_refs})
 end
 table.sort(descriptors,function(a,b)return a.partition_id<b.partition_id end)
 table.sort(payloads,function(a,b)return a.partition_id<b.partition_id end)
 local index=json.object();for ref,e in pairs(data.index)do index[ref]=json.object(e)end
 local wire=json.object({next_ref=data.next_ref,next_uid=require('engine.Entity').native_uid_state(),dirty_blobs=payloads,descriptors=descriptors})
 if hot_delta then
  assert(type(committed_hot)=='table','missing committed hot refs')
  local retired=json.array();for ref in pairs(committed_hot)do if not index[ref] then retired[#retired+1]=ref end end;table.sort(retired)
  for _,ref in ipairs(protected_refs)do assert(index[ref],'protected hot reference retired') end
  wire.objects_delta=json.object({format='tome-hot-index-delta-v1',owner='hot',records=index,retired=retired})
 else wire.objects=index end
 return wire,r,plan,hot_provider
end

-- Load only blobs authorized for the operation. A missing owner is an error;
-- a caller must never substitute reconstructed or client-supplied objects.
function M.reader(manifest,blobs,existing_registry)
 assert(type(manifest)=='table' and type(manifest.objects)=='table' and type(blobs)=='table','invalid native partition input')
 local parts={};local total=0
 for _,b in ipairs(blobs)do
  assert(type(b.partition_id)=='string' and not parts[b.partition_id],'duplicate native partition')
  total=total+#b.payload_base64;assert(total<=180*1024*1024,'partition request limit')
  parts[b.partition_id]=bundle.decode(b.partition_id,b.payload_base64)
 end
 local hot=assert(parts.hot,'hot partition missing')
 local reader=partition.reader(manifest.objects,manifest.next_ref,
  function(owner,ref)local p=assert(parts[owner],'authorized partition missing');return p.fragments[ref]end,
  assert(hot.function_env,'missing native function environment'),
  function(owner,ref)local p=assert(parts[owner],'authorized partition missing');return p.functions[ref]end,
  function(owner)return assert(parts[owner],'authorized partition missing')end,existing_registry)
 return reader,parts
end
-- Commit-confirmed hot blob replaces the old provider before any weak fixup.
-- The caller has already authenticated and committed this exact candidate.
function M.rebase_reader(reader,parts,wire,writer,committed_hot,provider)
 assert(type(provider)=='table' and provider.format=='tome-native-partition-v1' and provider.owner=='hot','missing private committed hot provider')
 assert(#wire.dirty_blobs==1 and wire.dirty_blobs[1].partition_id=='hot' and provider.root_ref==wire.dirty_blobs[1].root_ref,'invalid private hot provider')
 if wire.objects_delta then reader:rebase_hot_delta(wire.objects_delta,wire.next_ref,provider,writer,committed_hot) else reader:rebase_hot(wire.objects,wire.next_ref,provider,writer) end
 parts.hot=provider
 reader:refresh_weak()
end

function M.bind_root(root,shell)
 require('formal_factory').install_object_resolver()
 local restored=assert(root.game)
 for _,key in ipairs({'dialogs','__coroutines','nicer_tiles','uiset','target','flyers','log','logNewest','logRollback','playSound','playSoundNear','can_pause','calendar','__mod_info','delayed_log_messages','delayed_log_damage','tiles_attachements','tiles_facing','bignews'})do
  if rawget(restored,key)==nil then rawset(restored,key,rawget(shell,key)) end
 end
 assert(type(shell.real_starttime)=='number','missing native session clock')
 restored.real_starttime=shell.real_starttime;restored.last_update=nil
 _G.game=restored;_G.world=assert(root.world)
 local Zone=require 'mod.class.Zone'
 Zone:setup{npc_class='mod.class.NPC',grid_class='mod.class.Grid',object_class='mod.class.Object',trap_class='mod.class.Trap',on_setup=function(z)game:applyDifficulty(z)end}
 Zone.check_filter=function(...)return game.state:entityFilter(...)end
 Zone.default_prob_filter=true
 Zone.default_filter=function(...)return game.state:defaultEntityFilter(...)end
 Zone.alter_filter=function(...)return game.state:entityFilterAlter(...)end
 Zone.post_filter=function(...)return game.state:entityFilterPost(...)end
 Zone.ego_filter=function(...)return game.state:egoFilter(...)end
end
function M.loaded_game(g)
 assert(not (g.zone and g.zone.on_loaded),'native Game zone on_loaded lifecycle unsupported')
 local base=require 'engine.Game';local old=base.loaded
 base.loaded=function(x)x.__coroutines=x.__coroutines or {};x.dialogs={}end
 local ok,err=xpcall(function()require('engine.GameEnergyBased').loaded(g)end,debug.traceback)
 base.loaded=old;if not ok then error(err)end
end
return M
