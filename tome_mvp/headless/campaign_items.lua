-- Native inventory operations. Caller must persist/replay the complete state and
-- serialize access; this module is not a durable transaction coordinator.
local json=require 'json_validate'
local M={}
local active_state
local responding_native_input=false
-- Instrument the native player use entry, preserving return values and effects.
-- A receipt is only a candidate until the item is absent at reconciliation.
function M.install(state)
 active_state=state
 local Object=require 'mod.class.Object'
 if Object._dm_use_receipt_installed then return end
 local original=Object.use
 Object.use=function(self,who,...)
  local result=original(self,who,...)
  if self._dm_item_id and active_state and active_state._dm_item_objects and active_state._dm_item_objects[self._dm_item_id]==self and result and result.used and result.destroy then
   active_state._dm_item_use_receipts=active_state._dm_item_use_receipts or {}
   active_state._dm_item_use_receipts[self._dm_item_id]={item=self,uid=self.uid,actor_id=who._dm_world_id,turn=game.turn}
  end
  if self._dm_item_id and active_state and active_state._dm_item_objects and active_state._dm_item_objects[self._dm_item_id]==self and require('native_inputs').has_pending() and not (result and result.used) then
   active_state._dm_item_deferred_use=active_state._dm_item_deferred_use or {}
   active_state._dm_item_deferred_use[self._dm_item_id]={item=self,uid=self.uid,actor=who}
  end
  return result
 end
 local inputs=require 'native_inputs'
 local removed_gem
 local original_respond=inputs.respond
 inputs.respond=function(answer)
  responding_native_input=not answer.cancel
  local ok,err=xpcall(function()original_respond(answer)end,debug.traceback)
  responding_native_input=false
  if ok and removed_gem then
   for _,armor in ipairs(removed_gem.armor) do if armor.been_imbued then
    local o=removed_gem.item
    active_state._dm_item_use_receipts=active_state._dm_item_use_receipts or {}
    active_state._dm_item_use_receipts[o._dm_item_id]={item=o,uid=o.uid,actor_id=removed_gem.actor_id,turn=game.turn}
    break
   end end
  end
  removed_gem=nil
  if active_state and not inputs.has_pending() then active_state._dm_item_deferred_use={} end
  if not ok then error(err) end
 end
 local Player=require 'mod.class.Player'
 local remove=Player.removeObject
 Player.removeObject=function(who,...)
  local o,finish=remove(who,...)
  local pending=active_state and active_state._dm_item_deferred_use
  local entry=o and pending and pending[o._dm_item_id]
  -- Imbue Item removes the selected gem before it applies the permanent ego.
  -- Both changes must occur in the same successful native choice callback.
  if responding_native_input and o and o._dm_item_id and o.type=='gem' and o.imbue_powers and
     active_state and active_state._dm_item_objects[o._dm_item_id]==o then
   local armor={}
   for _,item in ipairs(who:getInven('INVEN')) do
    if item.type=='armor' and not item.been_imbued then armor[#armor+1]=item end
   end
   removed_gem={item=o,actor_id=who._dm_world_id,armor=armor}
  end
  if responding_native_input and entry and entry.item==o and entry.actor==who and entry.uid==o.uid then
   active_state._dm_item_use_receipts=active_state._dm_item_use_receipts or {}
   active_state._dm_item_use_receipts[o._dm_item_id]={item=o,uid=o.uid,actor_id=who._dm_world_id,turn=game.turn}
   if pending then pending[o._dm_item_id]=nil end
  end
  return o,finish
 end
 for _,class in ipairs({require('mod.class.Player'),require('mod.class.PartyMember')})do
  local pickup=class.pickupFloor
  class.pickupFloor=function(self,pos,...)
   local map=active_state and active_state.map
   if self._dm_world_id and self.x and self.y and map and game.level and game.level.map==map then
    local item=map:getObject(self.x,self.y,pos)
    if item and item.type=='money' then return end
   end
   return pickup(self,pos,...)
  end
 end
 Object._dm_use_receipt_installed=true
end
local function text(x) return type(x)=='string' and #x>0 and #x<=128 end
local function keys(t,allowed)
 assert(type(t)=='table','object required')
 for k in pairs(t) do assert(allowed[k], 'unknown field '..tostring(k)) end
end
local function actor(state,id)
 local found
 for _,a in ipairs(require('company_roster').members(state)) do if a._dm_world_id==id then assert(not found,'duplicate actor');found=a end end
 return assert(found,'unknown actor')
end
local function locate(state,id)
 local result
 for _,a in ipairs(require('company_roster').members(state)) do
  for slot,inv in pairs(a.inven or {}) do if type(slot)=='number' and type(inv)=='table' then
   for pos,o in ipairs(inv) do o:forAllStack(function(v) if v._dm_item_id==id then assert(not result,'duplicate item identity'); result={actor=a,slot=slot,pos=pos,item=v,stacked=v~=o or o:getNumber()~=1} end end) end
  end end
 end
 return result
end
function M.apply(state,world_id,req)
 if type(req)=='table' and type(req.operation)=='string' and req.operation:match('^company_') then
  assert(state._dm_items_world==world_id,'native inventory world mismatch')
  return require('company_roster').apply(state,req)
 end
 M.install(state)
 if type(req)=='table' and req.operation=='transmogrify' then return M.transmogrify_bag(state,world_id,req) end
 if type(req)=='table' and req.operation=='loot_settle' then return M.settle_loot(state,world_id,req) end
 if type(req)=='table' and req.operation=='prepare_craft' then return M.prepare_craft(state,world_id,req) end
 if type(req)=='table' and req.operation=='prepare_sustain' then return require('campaign_loadout').prepare(state,world_id,req) end
 if type(req)=='table' and req.operation=='progression' then return require('character_editor').apply(state,world_id,req) end
 if type(req)=='table' and (req.operation=='equip' or req.operation=='unequip' or req.operation=='switch_set') then
  return require('campaign_loadout').apply(state,world_id,req)
 end
 keys(req,{action_id=true,operation=true,actor_id=true,target_actor_id=true,item_id=true,item_spec=true,destination=true,source_location=true})
 assert(text(world_id),'invalid trusted world')
 assert(state._dm_items_world==nil or state._dm_items_world==world_id,'world mismatch')
 assert(text(req.action_id) and text(req.actor_id) and text(req.item_id),'invalid identity')
 assert(req.operation=='add' or req.operation=='remove' or req.operation=='transfer','invalid operation')
 local a=actor(state,req.actor_id)
 state._dm_items_world=world_id
 state._dm_inventory_actions=state._dm_inventory_actions or {}
 state._dm_item_ids=state._dm_item_ids or {}
 state._dm_ground_items=state._dm_ground_items or {}
 state._dm_item_objects=state._dm_item_objects or {}
 state._dm_item_holders=state._dm_item_holders or {}
 local signature=json.encode(req)
 local prior=state._dm_inventory_actions[req.action_id]
 if prior then assert(prior.signature==signature,'action id conflict');return prior.receipt end
 local result
 if req.operation=='add' then
  assert(req.target_actor_id==nil and req.destination==nil,'unexpected destination')
  local ground=state._dm_ground_items[req.item_id]
  if ground then
   assert(not ground.attached,'pick up the containing gear')
   assert(not ground.offline,'ground item requires its native floor to be loaded')
   assert(req.item_spec==nil and req.source_location==ground.location,'ground location mismatch')
   assert(ground.item._dm_world_id==world_id and not locate(state,req.item_id),'ground identity mismatch')
   local inv=assert(a:getInven(a.INVEN_INVEN),'bag missing');assert(#inv<inv.max,'bag full')
   if ground.map then local pos=assert(ground.map:findObject(ground.x,ground.y,ground.item),'ground object missing');assert(ground.map:removeObject(ground.x,ground.y,pos),'ground removal failed') end
   assert(a:addObject(a.INVEN_INVEN,ground.item,true),'native pickup rejected')
   state._dm_ground_items[req.item_id]=nil
   result=json.object({action_id=req.action_id,operation='add',item_id=req.item_id,uid=ground.item.uid,actor_id=req.actor_id,history_ref=ground.item._dm_history_ref or json.null,history_hash=ground.item._dm_history_hash or json.null})
  else
  assert(req.source_location==nil and not state._dm_item_ids[req.item_id] and not locate(state,req.item_id),'item identity already used')
  local spec=req.item_spec
  keys(spec,{prototype=true,history_ref=true,history_hash=true,history_type=true,history_subtype=true})
  assert(text(spec.prototype),'invalid prototype')
  assert((spec.history_ref==nil and spec.history_hash==nil and spec.history_type==nil and spec.history_subtype==nil) or (text(spec.history_ref) and text(spec.history_hash) and text(spec.history_type) and text(spec.history_subtype)),'invalid history binding')
  if spec.prototype=='ordinary document' then require('project_items').install(game.zone.object_list) end
  local prototype
  for _,p in ipairs(game.zone.object_list or {}) do if p.name==spec.prototype or p.define_as==spec.prototype then assert(not prototype,'ambiguous prototype');prototype=p end end
  assert(prototype,'unknown prototype')
  if spec.history_ref then assert(prototype.type==spec.history_type and prototype.subtype==spec.history_subtype,'history prototype type mismatch') end
  -- Fixed uniques must be governed by the native global uniqueness mechanism.
  -- Until it is independently verified, exclude them from this boundary.
  assert(not prototype.unique and not prototype.artifact,'native unique prototype unsupported')
  local inv=assert(a:getInven(a.INVEN_INVEN),'bag missing')
  assert(#inv<inv.max,'bag full')
  local o=assert(game.zone:finishEntity(game.level,'object',prototype,-1000),'native construction failed')
  assert(o.uid and o:getNumber()==1,'unsupported quantity')
  o._dm_item_id=req.item_id;o._dm_world_id=world_id;o._dm_history_ref=spec.history_ref;o._dm_history_hash=spec.history_hash
  o:identify(true)
  local added=assert(a:addObject(a.INVEN_INVEN,o,true),'native add rejected')
  assert(added and locate(state,req.item_id),'native add not retained')
  state._dm_item_ids[req.item_id]=true
  state._dm_item_objects[req.item_id]=o
  result=json.object({action_id=req.action_id,operation='add',item_id=req.item_id,uid=o.uid,actor_id=req.actor_id,prototype=spec.prototype,history_ref=spec.history_ref or json.null,history_hash=spec.history_hash or json.null})
  end
 else
  assert(req.item_spec==nil and req.source_location==nil,'unexpected item spec')
  local found=assert(locate(state,req.item_id),'item not found')
  assert(found.item._dm_world_id==world_id,'item world mismatch')
  assert(found.actor==a and found.slot==a.INVEN_INVEN,'item is not in actor bag')
  assert(not found.stacked,'stacked item operation unsupported')
  local target
  if req.operation=='transfer' then
   assert(req.destination==nil and text(req.target_actor_id) and req.target_actor_id~=req.actor_id,'invalid target')
   target=actor(state,req.target_actor_id)
   local inv=assert(target:getInven(target.INVEN_INVEN),'target bag missing')
   assert(#inv<inv.max,'target bag full')
  else
   assert(req.target_actor_id==nil,'unexpected target')
   keys(req.destination,{kind=true,id=true})
   assert(req.destination.kind=='world_location' and text(req.destination.id),'world location destination required')
  end
  local o=assert(a:removeObject(a.INVEN_INVEN,found.pos,true),'native removal rejected')
  assert(o==found.item,'native removal identity mismatch')
  if target then
   if not target:addObject(target.INVEN_INVEN,o,true) then
    assert(a:addObject(a.INVEN_INVEN,o,true),'rollback failed')
    error('native transfer rejected')
   end
  else
   if state._dm_area_outside then
    state._dm_ground_items[req.item_id]={item=o,location=req.destination.id}
   else
    assert(state.map and state.map:addObject(a.x,a.y,o),'native ground placement rejected')
    state._dm_ground_items[req.item_id]={item=o,location=req.destination.id,map=state.map,x=a.x,y=a.y}
   end
  end
  result=json.object({action_id=req.action_id,operation=req.operation,item_id=req.item_id,uid=o.uid,actor_id=req.actor_id,target_actor_id=req.target_actor_id or json.null})
 end
 if req.operation=='remove' then state._dm_item_holders[req.item_id]={kind='world_location',id=req.destination.id}
 elseif req.operation=='transfer' then state._dm_item_holders[req.item_id]={kind='actor',id=req.target_actor_id}
 else state._dm_item_holders[req.item_id]={kind='actor',id=req.actor_id} end
 state._dm_inventory_actions[req.action_id]={signature=signature,receipt=result}
 return result
end
-- Public player choice surface. It contains only the controlled actor's
-- ordinary inventory slots and native display names, never private fields.
function M.list(state)
 local a=assert(state.player,'no controlled actor')
 assert(a==game.player and text(a._dm_world_id),'controlled actor identity missing')
 local out=json.array()
 for slot,inv in pairs(a.inven or {}) do if type(slot)=='number' and type(inv)=='table' then
  local def=a.inven_def and a.inven_def[slot]
  if def and text(def.short_name) then for pos,o in ipairs(inv) do
   local name=o:getName{do_color=false}
   out[#out+1]=json.object({actor_id=a._dm_world_id,slot=def.short_name,pos=pos,uid=o.uid,name=tostring(name)})
   assert(#out<=2000,'inventory exceeds projection limit')
  end end
 end end
 table.sort(out,function(x,y)return x.slot==y.slot and x.pos<y.pos or x.slot<y.slot end)
 return out
end
-- Validate before the worker accepts a player request. Ordinary invalid
-- selections are rejections; exceptions in native callbacks remain unknown.
function M.check_use(state,req)
 if type(req)~='table' then return false,'invalid_item_request' end
 local allowed={actor_id=true,slot=true,pos=true,uid=true}
 for key in pairs(req) do if not allowed[key] then return false,'invalid_item_request' end end
 if not text(req.actor_id) or not text(req.slot) then return false,'invalid_item_identity' end
 if type(req.pos)~='number' or req.pos<1 or req.pos~=math.floor(req.pos) or type(req.uid)~='number' or req.uid<1 or req.uid~=math.floor(req.uid) then return false,'invalid_item_identity' end
 local a=state.player
 if not a or a~=game.player or a._dm_world_id~=req.actor_id then return false,'actor_not_controlled' end
 if a.dead or a.no_inventory_access or not game.zone or game.zone.wilderness then return false,'inventory_unavailable' end
 if require('native_inputs').has_pending() then return false,'native_input_pending' end
 local slot=a['INVEN_'..req.slot]
 if not slot then return false,'unknown_inventory_slot' end
 local inv=a:getInven(slot)
 local o=inv and inv[req.pos]
 if not o or o.uid~=req.uid then return false,'stale_item' end
 if o:getNumber()~=1 then return false,'stack_unsupported' end
 local permitted=o:canUseObject(a)
 if not permitted then return false,'native_item_unavailable' end
 return true
end
-- Player request only. Worker owns turn settlement and any native inputs.
function M.use(state,req)
 local valid,reason=M.check_use(state,req);assert(valid,reason)
 keys(req,{actor_id=true,slot=true,pos=true,uid=true})
 assert(text(req.actor_id) and text(req.slot),'invalid actor or slot')
 assert(type(req.pos)=='number' and req.pos>=1 and req.pos==math.floor(req.pos),'invalid inventory position')
 assert(type(req.uid)=='number' and req.uid>=1 and req.uid==math.floor(req.uid),'invalid object UID')
 local a=actor(state,req.actor_id)
 assert(a==state.player and a==game.player,'actor is not controlled')
 assert(not a.dead and not a.no_inventory_access and game.zone and not game.zone.wilderness,'inventory use unavailable')
 assert(not require('native_inputs').has_pending(),'native input pending')
 local slot=assert(a['INVEN_'..req.slot],'unknown inventory slot')
 local inv=assert(a:getInven(slot),'inventory slot unavailable')
 local o=assert(inv[req.pos],'item position empty')
 assert(o.uid==req.uid and o:getNumber()==1,'item UID mismatch or stack unsupported')
 local permitted,reason=o:canUseObject(a)
 assert(permitted,'native use denied: '..tostring(reason))
 local before=a.energy.value
 local accepted=a:playerUseItem(o,req.pos,slot)
 assert(accepted,'native use declined')
 return {uid=o.uid,input_pending=require('native_inputs').has_pending(),energy_spent=a.energy.value<before}
end
-- Register existing native inventory without constructing or moving objects.
-- The host must journal this operation and validate its replay before accepting
-- the resulting IDs. Campaign scope is encoded into the stable ID.
function M.adopt(state,world_id,campaign_id)
 assert(text(world_id) and text(campaign_id) and #campaign_id<=64 and campaign_id:match('^[%w_-]+$'),'invalid campaign scope')
 assert(state._dm_items_world==nil or state._dm_items_world==world_id,'world mismatch')
 assert(state._dm_items_campaign==nil or state._dm_items_campaign==campaign_id,'campaign mismatch')
 local items,seen_uid,seen_id={}, {}, {}
 local objects=state._dm_item_objects or {};local ids=state._dm_item_ids or {}
 local holders=state._dm_item_holders or {}
 for _,a in ipairs(require('company_roster').members(state)) do
  assert(text(a._dm_world_id),'unbound actor')
  for slot,inv in pairs(a.inven or {}) do if type(slot)=='number' and type(inv)=='table' then
   local def=a.inven_def and a.inven_def[slot]
   assert(def and text(def.short_name),'unknown inventory slot')
   for pos,base in ipairs(inv) do
    local function register(o)
     assert(type(o.uid)=='number' and o.uid>0 and o.uid==math.floor(o.uid) and not seen_uid[o.uid],'invalid or duplicate UID')
     seen_uid[o.uid]=true
     local id=o._dm_item_id or ('native:'..campaign_id..':'..tostring(o.uid))
     assert(text(id) and not seen_id[id],'duplicate item identity');seen_id[id]=true
     if o._dm_item_id then
      assert(o._dm_world_id==world_id and objects[id]==o and ids[id], 'unregistered bound item')
     else
      assert(not o._dm_relic_id,'legacy relic binding requires reconciliation')
      assert(not objects[id] and not ids[id],'world item identity already reserved')
     end
     items[#items+1]={item=o,id=id,actor=a,slot=def.short_name,pos=pos,stacked=base~=o or base:getNumber()~=1}
    end
    base:forAllStack(function(o) register(o);if o.tinker then register(o.tinker) end end)
   end
  end end
 end
 state._dm_items_world=world_id;state._dm_items_campaign=campaign_id
 state._dm_item_objects=objects;state._dm_item_ids=ids;state._dm_item_holders=holders
 state._dm_ground_items=state._dm_ground_items or {};state._dm_inventory_actions=state._dm_inventory_actions or {}
 M.install(state)
 local out=json.array()
 table.sort(items,function(a,b)return a.item.uid<b.item.uid end)
 for _,entry in ipairs(items) do
  local o=entry.item;o._dm_item_id=entry.id;o._dm_world_id=world_id
  objects[entry.id]=o;ids[entry.id]=true
  if not holders[entry.id] then holders[entry.id]={kind='actor',id=entry.actor._dm_world_id} end
  out[#out+1]=json.object({item_id=entry.id,uid=o.uid,actor_id=entry.actor._dm_world_id,slot=entry.slot,pos=entry.pos,stacked=entry.stacked,name=o.name or ''})
 end
 return out
end
-- Observe actual native holdings at a trusted decision boundary. The host must
-- journal and reconcile returned changes before acknowledging a checkpoint.
function M.reconcile(state,world_id,world_location,observation_id)
 assert(state._dm_items_world==nil or state._dm_items_world==world_id,'world mismatch')
 assert(text(world_location),'world location required')
 if observation_id then
  assert(text(observation_id),'invalid observation ID')
  state._dm_item_observations=state._dm_item_observations or {}
  local previous=state._dm_item_observations[observation_id]
  if previous then assert(previous.world==world_id and previous.location==world_location,'observation conflict');return previous.changes end
 end
 local objects=state._dm_item_objects or {};local holders=state._dm_item_holders or {}
 local ground=state._dm_ground_items or {};local observed={}
 local function mark(o,holder,map,x,y,attached)
  if o.tinker then mark(o.tinker,holder,map,x,y,true) end
  if not o._dm_item_id then return end
  local id=o._dm_item_id
  assert(objects[id]==o and o._dm_world_id==world_id,'unknown or copied item')
  assert(not observed[id],'duplicate item presence')
  observed[id]={item=o,holder=holder,map=map,x=x,y=y,attached=attached}
 end
 for _,a in ipairs(require('company_roster').members(state)) do
  for slot,inv in pairs(a.inven or {}) do if type(slot)=='number' and type(inv)=='table' then
   for _,o in ipairs(inv) do o:forAllStack(function(v) mark(v,{kind='actor',id=a._dm_world_id}) end) end
  end end
 end
 for id,carrier in pairs(state._dm_world_person_actors or {})do
  for _,item in ipairs(carrier._dm_wipeout_spoils or {})do
   item:forAllStack(function(o)mark(o,{kind='actor',id=id})end)
  end
 end
 -- The party may already have travelled while this is still the previous
 -- native scene. A map's ground does not travel with the party.
 local active_area=state._dm_local_areas and state._dm_local_areas[state._dm_current_area]
 assert(state.map or state._dm_area_outside,'missing active native map')
 local map_location=active_area and active_area.tile_id or (state.map and state.map._dm_world_location) or world_location
 if state.map then
 state.map._dm_world_location=map_location
 for y=0,state.map.h-1 do for x=0,state.map.w-1 do
  for i=1,state.map:getObjectTotal(x,y) do
   local o=state.map:getObject(x,y,i);local prior=o._dm_item_id and ground[o._dm_item_id]
   local location=prior and prior.map==state.map and prior.location or map_location
   mark(o,{kind='world_location',id=location},state.map,x,y)
  end
 end end
 end
 for id,e in pairs(ground) do
  if e.offline then
   assert(not objects[id] and e.ref and e.uid and e.location,"invalid offline ground identity")
   assert(holders[id] and holders[id].kind=="world_location" and holders[id].id==e.location,"offline ground holder mismatch")
  elseif e.attached then
   -- The containing gear is visited once, including its attached part.
  elseif e.map and e.map~=state.map then
   -- Persistent areas keep their ground objects on the original native Map.
   -- Absence from the active floor is not consumption or loss.
   assert(e.map:findObject(e.x,e.y,e.item),'saved area ground object missing')
   mark(e.item,{kind='world_location',id=e.location},e.map,e.x,e.y)
  elseif not e.map then
   mark(e.item,{kind='world_location',id=e.location})
  end
 end
 local changes=json.array()
 for id,o in pairs(objects) do
  local now=observed[id]
  local old=assert(holders[id],'native item holder missing')
  if not now then
   local used=(state._dm_item_use_receipts or {})[id]
   assert(used and used.item==o and used.uid==o.uid,'native item missing without consumption receipt')
   assert((old.kind=='actor' and used.actor_id==old.id) or
          (old.kind=='world_location' and used.source_location==old.id and text(used.actor_id)),
          'native consumption holder mismatch')
   now={item=o,holder={kind='consumed',id=used.actor_id},consumed=true,turn=used.turn};observed[id]=now
  end
  if old.kind~=now.holder.kind or old.id~=now.holder.id then
   changes[#changes+1]=json.object({item_id=id,uid=o.uid,from=json.object({kind=old.kind,id=old.id}),to=json.object({kind=now.holder.kind,id=now.holder.id}),turn=now.consumed and now.turn or json.null})
  end
 end
 table.sort(changes,function(a,b)return a.item_id<b.item_id end)
 for id,now in pairs(observed) do
  holders[id]=now.holder
  if now.holder.kind=='actor' or now.consumed then ground[id]=nil
  else ground[id]={item=now.item,location=now.holder.id,map=now.map,x=now.x,y=now.y,attached=now.attached} end
  if state._dm_item_use_receipts then state._dm_item_use_receipts[id]=nil end
  if state._dm_item_deferred_use then state._dm_item_deferred_use[id]=nil end
  if now.consumed then objects[id]=nil end
 end
 state._dm_item_holders=holders;state._dm_ground_items=ground
 if observation_id then state._dm_item_observations[observation_id]={world=world_id,location=world_location,changes=changes} end
 return changes
end
-- ToME Actor:transmoInven values each member of a stack separately.
-- Compute a quote without removing the item or crediting the actor's purse.
local function transmo_value(actor,item)
 if item.tinker or not actor:transmoFilter(item) then return nil end
 return math.min(item:getPrice()*actor:transmoPricemod(item),25)
end

function M.transmo_quote(actor,item,single)
 if single then
  local value=transmo_value(actor,item)
  return value and (value~=value and 100 or math.floor(value*100))
 end
 local total=0
 local eligible=true
 item:forAllStack(function(object)
  local value=transmo_value(actor,object)
  if not value then eligible=false;return end
  total=total+value
 end)
 if not eligible then return nil end
 if total~=total then return 100 end
 return math.floor(total*100)
end

-- Move the selected unit to the native unstack position without changing its UID.
local function select_stack_unit(inv,pos,item)
 local base=inv[pos]
 if base==item and (not base.stacked or #base.stacked==0) then return end
 local stack=assert(base.stacked)
 if base==item then
  local replacement=table.remove(stack,1)
  base.stacked=nil
  replacement.stacked=stack
  stack[#stack+1]=base
  inv[pos]=replacement
 else
  for i,unit in ipairs(stack)do
   if unit==item then table.remove(stack,i);stack[#stack+1]=unit;return end
  end
  error('stack item unavailable')
 end
end

local function reagent(o)
 return o.type=='gem' and not (o.unique or o.__tagged or o._dm_relic_id or o.quest or o.plot)
end

function M.craft_choices(state,a,id)
 local choices=json.array()
 if id=='T_CREATE_ALCHEMIST_GEMS' then
  for _,holder in ipairs(require('company_roster').members(state))do
   for _,base in ipairs(holder:getInven('INVEN') or {})do
    base:forAllStack(function(o)
     if o._dm_item_id and reagent(o) then
      choices[#choices+1]=json.object({item_id=o._dm_item_id,label=tostring(o:getName{do_color=false,no_count=true})})
     end
    end)
   end
  end
 else
  local party=game.party
  for recipe,def in pairs(party.__tinkers_ings or {})do
   if party:knowTinker(recipe) and not def.create and not def.items then
    for tier=1,5 do
     if party:canMakeTinker(a,recipe,tier) then
      choices[#choices+1]=json.object({recipe=recipe,tier=tier,label=tostring(def.name)..' · '..tier})
     end
    end
   end
  end
 end
 table.sort(choices,function(x,y)
  if x.label~=y.label then return x.label<y.label end
  return (x.item_id or x.recipe)<(y.item_id or y.recipe)
 end)
 return choices
end

function M.prepare_craft(state,world,req)
 keys(req,{operation=true,action_id=true,actor_id=true,talent_id=true,item_id=true,recipe=true,tier=true})
 assert(state._dm_items_world==world and state._dm_area_outside and game.zone and game.level,'crafting requires a camp boundary')
 local a=actor(state,req.actor_id)
 local id=req.talent_id
 assert(text(req.action_id) and not a.no_inventory_access and not a.dead and not require('rescue').is_down(a)
  and (id=='T_CREATE_ALCHEMIST_GEMS' or id=='T_CREATE_TINKER') and a:knowTalent(id),'camp crafting unavailable')
 local actions=assert(state._dm_inventory_actions)
 local signature=json.encode(req)
 local prior=actions[req.action_id]
 if prior then assert(prior.signature==signature,'action id conflict');return prior.receipt end
 local realm=require 'native_inputs'
 if id=='T_CREATE_ALCHEMIST_GEMS' then
  assert(text(req.item_id) and not req.recipe and not req.tier,'invalid gemstone selection')
  local found=assert(locate(state,req.item_id),'gemstone unavailable')
  local holder,o=found.actor,found.item
  assert(found.slot==holder.INVEN_INVEN and reagent(o),'gemstone unavailable')
  local original=holder:getInven(found.slot)
  select_stack_unit(original,found.pos,o)
  local offered=original[found.pos]
  if holder~=a then
   assert(holder:removeObject(original,found.pos)==o and a:addObject(a.INVEN_INVEN,o,true),'shared gemstone unavailable')
   offered=o
  end
  a:forceUseTalent(id,{ignore_energy=true})
  assert(realm.has_pending() and not a.talent_error,'native gem menu unavailable')
  realm.choose_object(offered)
  assert(not locate(state,req.item_id),'selected gemstone was not consumed')
  state._dm_item_use_receipts=state._dm_item_use_receipts or {}
  state._dm_item_use_receipts[req.item_id]={item=o,uid=o.uid,actor_id=holder._dm_world_id,turn=game.turn}
 else
  local party=game.party
  local def=party.__tinkers_ings and party.__tinkers_ings[req.recipe]
  assert(not req.item_id and def and party:knowTinker(req.recipe) and not def.create and not def.items
    and type(req.tier)=='number' and req.tier==math.floor(req.tier) and req.tier>=1 and req.tier<=5
    and party:canMakeTinker(a,req.recipe,req.tier),'native tinker recipe unavailable')
  party:makeTinker(a,req.recipe,req.tier,true)
 end
 assert(not realm.has_pending() and not next(game.__coroutines),'native crafting suspended')
 local new={}
 for _,base in ipairs(a:getInven('INVEN'))do
  base:forAllStack(function(o)if not o._dm_item_id then new[o.uid]=true end end)
 end
 local adopted=json.array()
 for _,item in ipairs(M.adopt(state,world,state._dm_items_campaign))do
  if new[item.uid] then adopted[#adopted+1]=item end
 end
 assert(#adopted>0,'native crafting produced no item')
 local receipt=json.object({operation=req.operation,action_id=req.action_id,actor_id=req.actor_id,
  talent_id=id,adopted=adopted})
 actions[req.action_id]={signature=signature,receipt=receipt}
 return receipt
end

-- Use Embers' native APE rules to stock the shared crafting ingredients.
-- The campaign receipt owns all gold credit.
local function collect_tinker_materials(state,item)
 if not game.party.collectIngredient or not game.party.__ingredients_def then return end
 for _,member in ipairs(require('company_roster').members(state))do
  if member:knowTalent('T_CREATE_TINKER') then
   local leader=state.allies[1]
   local original=rawget(leader,'incMoney')
   leader.incMoney=function()end
   local ok,err=pcall(leader.transmoInven,leader,nil,nil,item,{define_as='APE'})
   rawset(leader,'incMoney',original)
   if not ok then error(err,0) end
   return
  end
 end
end

function M.transmogrify_bag(state,world_id,req)
 keys(req,{operation=true,action_id=true,actor_id=true,item_id=true,transmo_cents=true,confirmed_relic=true})
 assert(state._dm_items_world==world_id and state._dm_area_outside,'transformation requires a camp boundary')
 assert(text(req.action_id) and text(req.actor_id) and text(req.item_id) and
        type(req.confirmed_relic)=='boolean','invalid transformation selection')
 local actions=assert(state._dm_inventory_actions)
 local signature=json.encode(req)
 local previous=actions[req.action_id]
 if previous then
  assert(previous.signature==signature,'action id conflict')
  return previous.receipt
 end
 local found=assert(locate(state,req.item_id),'item not found')
 local a,o=found.actor,found.item
 assert(a._dm_world_id==req.actor_id and found.slot==a.INVEN_INVEN and
        state._dm_item_objects[req.item_id]==o,'item must be in the shared bag')
 local inv=a:getInven(found.slot)
 local whole_stack=o.slot=='QUIVER' and inv[found.pos]==o and o:getNumber()>1
 local relic=false
 local function check_relic(item)
  relic=relic or not not (item._dm_relic_id or item.quest or item.plot)
 end
 if whole_stack then o:forAllStack(check_relic) else check_relic(o) end
 assert(not relic or req.confirmed_relic,'relic confirmation required')
 local cents=M.transmo_quote(a,o,not whole_stack)
 assert(cents~=nil and cents==req.transmo_cents,'transformation quote changed')
 if not whole_stack then select_stack_unit(inv,found.pos,o) end
 assert(a:removeObject(inv,found.pos,whole_stack)==o and not locate(state,req.item_id),'native removal failed')
 collect_tinker_materials(state,o)
 state._dm_item_use_receipts=state._dm_item_use_receipts or {}
 o:forAllStack(function(item)
  local id=assert(item._dm_item_id,'unregistered transformation')
  assert(state._dm_item_objects[id]==item,'transformation identity mismatch')
  state._dm_item_use_receipts[id]={item=item,uid=item.uid,actor_id=req.actor_id,turn=game.turn}
 end)
 local receipt=json.object({operation=req.operation,action_id=req.action_id,actor_id=req.actor_id,
                            item_id=req.item_id,uid=o.uid,gold_cents=cents})
 actions[req.action_id]={signature=signature,receipt=receipt}
 return receipt
end

-- The same candidate walk serves both the preview and the trusted mutation.
local function loot_objects(state)
 if state._dm_wipeout or not state.map or state._dm_area_outside then return {},{} end
 local map=state.map
 local Map=require 'engine.Map'
 local candidates,money,queue,seen={},{},{},{}
 local directions={{1,0},{-1,0},{0,1},{0,-1},{1,1},{-1,-1},{1,-1},{-1,1}}
 local function enqueue(x,y)
  if not x or not y or not map:isBound(x,y) then return end
  local key=x+y*map.w
  if seen[key] then return end
  local terrain=map(x,y,Map.TERRAIN)
  if not terrain or terrain:check('block_move',x,y,state.player,false,false) then return end
  seen[key]=true
  queue[#queue+1]={x=x,y=y}
 end
 local rescue=require 'rescue'
 for _,a in ipairs(state.allies)do
  if not a.dead and not rescue.is_down(a) then enqueue(a.x,a.y) end
 end
 local cursor=1
 while cursor<=#queue do
  local p=queue[cursor];cursor=cursor+1
  for i=1,map:getObjectTotal(p.x,p.y)do
   local o=map:getObject(p.x,p.y,i)
   if o.droppedBy or o._dm_vault_loot then
    local entry={object=o,x=p.x,y=p.y}
    local list=o.type=='money' and money or candidates
    list[#list+1]=entry
   end
  end
  for _,d in ipairs(directions)do enqueue(p.x+d[1],p.y+d[2]) end
 end
 table.sort(candidates,function(a,b)return a.object.uid<b.object.uid end)
 return candidates,money
end

local function coin_value(rows)
 local cents=0
 for _,entry in ipairs(rows)do
  local value=entry.object.money_value
  assert(type(value)=='number' and value>=0 and value<1000000,'invalid native coin value')
  cents=cents+value*10
 end
 return math.floor(cents)
end

local function loot_terms(actor,object)
 local relic=false
 local attached=false
 object:forAllStack(function(o)
  relic=relic or not not (o._dm_relic_id or o.quest or o.plot)
  attached=attached or o.tinker~=nil
 end)
 local cents=M.transmo_quote(actor,object)
 return relic,cents,relic or attached or cents==nil
end

function M.loot_preview(state)
 local candidates=json.array()
 local items,money=loot_objects(state)
 for _,entry in ipairs(items)do
  local o=entry.object
  local relic,value,locked=loot_terms(state.player,o)
  local rgb=o:getDisplayColor()
  local ok,description=pcall(function()
   return require('localization').description(tostring(o:getDesc({no_compare=true},nil,true,state.player)),o)
  end)
  candidates[#candidates+1]=json.object({
    uid=o.uid,name=tostring(o:getName{do_color=false}):gsub('#[%w_]+#',''),count=o:getNumber(),
    type=o.type,icon=require('visual_metadata').icon(o.image),
    description=ok and description:gsub('#UID:[^#]+#',''):gsub('#[%w_]+#',''):sub(1,12000) or '',
    color=string.format('#%02x%02x%02x',rgb[1],rgb[2],rgb[3]),
    relic=relic,locked=locked,transmo_cents=value or json.null})
 end
 return candidates,coin_value(money)
end

-- Run on a disposable native candidate. The host journals this receipt before
-- publishing item custody, crediting the campaign treasury or leaving the floor.
function M.settle_loot(state,world_id,req)
 keys(req,{operation=true,action_id=true,location=true,choices=true})
 assert(state._dm_items_world==world_id and text(state._dm_items_campaign),'loot requires an adopted party')
 assert(text(req.action_id) and text(req.location) and json.isarray(req.choices),'invalid loot settlement')
 local signature=json.encode(req)
 local actions=assert(state._dm_inventory_actions)
 local previous=actions[req.action_id]
 if previous then
  assert(previous.signature==signature,'action id conflict')
  return previous.receipt
 end
 assert(state.map and not state._dm_area_outside and not state._dm_wipeout,'loot requires an active floor')
 local area=state._dm_local_areas and state._dm_local_areas[state._dm_current_area]
 local location=(area and area.tile_id) or state.map._dm_world_location
 assert(not location or location==req.location,'loot location mismatch')
 local leader=assert(state.allies[1])
 assert(text(leader._dm_world_id) and not leader.dead,'loot recipient unavailable')
 local candidates,money=loot_objects(state)
 assert(#req.choices==#candidates,'loot candidates changed')
 for i,entry in ipairs(candidates)do
  local choice=req.choices[i]
  keys(choice,{uid=true,keep=true,count=true,transmo_cents=true})
  local o=entry.object
  local _,value,locked=loot_terms(state.player,o)
  assert(choice.uid==o.uid and choice.count==o:getNumber() and choice.transmo_cents==(value or json.null),'loot candidate changed')
  assert(type(choice.keep)=='boolean' and (choice.keep or not locked),'locked loot must be retained')
 end
 local changes=json.array()
 for _,person in pairs(state._dm_world_person_index or {})do
  if person.wipeout_victor then
   changes=M.reconcile(state,world_id,req.location)
   break
  end
 end
 local new_uids,converted={},json.array()
 local coin_cents=coin_value(money)
 local gold_cents=coin_cents
 for _,entry in ipairs(money)do
  local pos=assert(state.map:findObject(entry.x,entry.y,entry.object),'coin pile moved before settlement')
  assert(state.map:removeObject(entry.x,entry.y,pos),'coin pickup rejected')
 end
 for i,entry in ipairs(candidates)do
  local o,choice=entry.object,req.choices[i]
  local pos=assert(state.map:findObject(entry.x,entry.y,o),'loot moved before settlement')
  assert(state.map:removeObject(entry.x,entry.y,pos),'loot removal failed')
  if choice.keep then
   o:forAllStack(function(item)
    if not item._dm_item_id then new_uids[item.uid]=true end
    if item.tinker and not item.tinker._dm_item_id then new_uids[item.tinker.uid]=true end
   end)
   assert(leader:addObject(leader.INVEN_INVEN,o,true),'shared bag could not retain loot')
  else
   o:forAllStack(function(item)
    local id=item._dm_item_id
    if id then
     assert(state._dm_item_objects[id]==item and state._dm_item_holders[id].kind=='world_location'
            and state._dm_item_holders[id].id==req.location,'converted loot custody mismatch')
     state._dm_item_use_receipts=state._dm_item_use_receipts or {}
     state._dm_item_use_receipts[id]={uid=item.uid,item=item,actor_id=leader._dm_world_id,
      source_location=req.location,turn=game.turn}
    end
   end)
   collect_tinker_materials(state,o)
   gold_cents=gold_cents+choice.transmo_cents
   converted[#converted+1]=json.object({uid=o.uid,count=choice.count,cents=choice.transmo_cents})
  end
 end
 local adopted=json.array()
 if next(new_uids) then
  for _,item in ipairs(M.adopt(state,world_id,state._dm_items_campaign))do
   if new_uids[item.uid] then adopted[#adopted+1]=item;new_uids[item.uid]=nil end
  end
  assert(not next(new_uids),'loot identity missing after pickup')
 end
 for _,change in ipairs(M.reconcile(state,world_id,req.location,req.action_id))do changes[#changes+1]=change end
 local receipt=json.object({operation='loot_settle',action_id=req.action_id,location=req.location,
  actor_id=leader._dm_world_id,gold_cents=gold_cents,coin_cents=coin_cents,adopted=adopted,converted=converted,changes=changes})
 actions[req.action_id]={signature=signature,receipt=receipt}
 return receipt
end

-- Call immediately before the old map is retired; replay recreates the same object.
function M.on_ground(map,x,y,item,attached)
 if not attached then return map:findObject(x,y,item) end
 for i=1,map:getObjectTotal(x,y) do if map:getObject(x,y,i).tinker==item then return true end end
end
function M.detach_ground(state)
 for _,entry in pairs(state._dm_ground_items or {}) do
  if entry.map then
   if not entry.attached then
    local pos=assert(entry.map:findObject(entry.x,entry.y,entry.item),'ground object missing')
    assert(entry.map:removeObject(entry.x,entry.y,pos),'ground detach failed')
   end
   entry.map=nil;entry.x=nil;entry.y=nil
  end
 end
end
return M
