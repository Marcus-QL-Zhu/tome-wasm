-- Camp-only native equipment boundary. Persistence and rollback are host-owned.
local json=require 'json_validate'
local M={}
local function socket_allowed(a,inv,pos)
 local limit=a.tinker_restrict_slots
 return inv.worn and a:attr('can_tinker') and (not limit or (limit[inv.name] or 0)>=pos)
end

function M.slots(a)
 local slots=json.array()
 for _,def in ipairs(a.inven_def) do
  local inv=a:getInven(def.id)
  if inv and (def.is_worn or def.is_shown_equip) then
   for pos=1,inv.max do
    local slot=def.short_name
    local gem=a:knowTalent(a.T_IMBUE_ITEM) and (slot=='BODY' or (a:knowTalent(a.T_CRAFTY_HANDS) and (slot=='HEAD' or slot=='BELT')))
    slots[#slots+1]=json.object({slot=slot,pos=pos,name=tostring(def.name),
     socket=socket_allowed(a,inv,pos) and true or false,imbue=gem and true or false})
   end
  end
 end
 return slots
end
local function find_actor(state,id)
 for _,a in ipairs(require('company_roster').members(state)) do if a._dm_world_id==id then return a end end
 error('unknown party actor')
end
local function find_item(state,id)
 for _,a in ipairs(require('company_roster').members(state)) do for slot,inv in pairs(a.inven or {}) do
  if type(slot)=='number' and type(inv)=='table' then for pos,o in ipairs(inv) do
   if o._dm_item_id==id then return a,slot,pos,o end
   if o.tinker and o.tinker._dm_item_id==id then return a,slot,pos,o.tinker,o end
  end end
 end end
 error('item absent from party')
end
function M.destinations(state,actor_id,item_id)
 local a=find_actor(state,actor_id)
 local source,inven,_,item,host=find_item(state,item_id)
 local result=json.array()
 if inven~=source.INVEN_INVEN or host or item.is_tinker then return result end
 local alternate=a:getObjectOffslot(item)
 for _,name in ipairs({item.slot,alternate}) do
  local inv=a:getInven(name)
  if inv and inv.worn and a:canWearObject(item,name) then result[#result+1]=name end
 end
 return result
end
function M.attachments(state,actor_id,slot,pos)
 local a=find_actor(state,actor_id)
 local inv=a:getInven(slot)
 local base=inv and inv[pos]
 local ids=json.array()
 if not base or not socket_allowed(a,inv,pos) then return ids end
 for _,member in ipairs(require('company_roster').members(state)) do
  for _,o in ipairs(member:getInven('INVEN') or {}) do
   if o._dm_item_id and o.is_tinker and o:getNumber()==1 and a:canUseTinker(o) and base:canAttachTinker(o,true)
    and (not o.on_special or o:on_special(base,a)) then ids[#ids+1]=o._dm_item_id end
  end
 end
 return ids
end
-- Reviewed self-only sustains with no targeting or temporary summons.
local camp_talents={T_SHIELD_WALL=true,T_ARCANE_POWER=true,T_ARCANE_SHIELD=true,
 T_FIRE_INFUSION=true,T_ACID_INFUSION=true,T_FROST_INFUSION=true,T_LIGHTNING_INFUSION=true}
function M.preparation(a,state)
 local skills=json.array()
 for id in pairs(camp_talents)do
  if a:knowTalent(id) and require('content_policy').allowed_talent(id) then
   local t=a:getTalentFromId(id)
   if t and t.mode=='sustained' then
    skills[#skills+1]=json.object({id=id,name=tostring(t.name),active=not not a:isTalentActive(id),
      icon=require('visual_metadata').icon(t.image),group=type(t.sustain_slots)=='string' and t.sustain_slots or nil})
   end
  end
 end
 for _,id in ipairs({'T_CREATE_ALCHEMIST_GEMS','T_CREATE_TINKER'})do
  if a:knowTalent(id) then
   local t=a:getTalentFromId(id)
   skills[#skills+1]=json.object({id=id,name=tostring(t.name),icon=require('visual_metadata').icon(t.image),
    choices=require('campaign_items').craft_choices(state,a,id)})
  end
 end
 table.sort(skills,function(x,y)return x.id<y.id end)
 return skills
end
function M.prepare(state,world,req)
 assert(state._dm_items_world==world and state._dm_area_outside,'camp preparation requires outside boundary')
 for key in pairs(req)do
  assert(({operation=true,action_id=true,actor_id=true,talent_id=true,active=true})[key],'invalid preparation field')
 end
 assert(type(req.action_id)=='string' and type(req.actor_id)=='string' and type(req.active)=='boolean','invalid preparation identity')
 local a=find_actor(state,req.actor_id)
 assert(not a.dead and not require('rescue').is_down(a),'actor unavailable')
 local id=req.talent_id
 assert(camp_talents[id] and require('content_policy').allowed_talent(id) and a:knowTalent(id),'skill unavailable at camp')
 local t=assert(a:getTalentFromId(id))
 assert(t.mode=='sustained','unsupported preparation skill')
 local g=state.game
 if (not not a:isTalentActive(id))~=req.active then
  assert(not next(g.__coroutines) and not require('native_inputs').has_pending(),'native action pending')
  assert(not (g.on_tick_end and next(g.on_tick_end.fcts)) and not g.on_tick_end_custom,'native callbacks pending')
  local captured={}
  g:onTickEndCapture(captured)
  local ok,result=xpcall(function()
   return a:forceUseTalent(id,{ignore_energy=true})
  end,debug.traceback)
  g:onTickEndCapture(nil)
  assert(ok,result)
  assert(result and not a.talent_error and not next(g.__coroutines) and not require('native_inputs').has_pending(),'preparation skill declined')
  for _,fn in ipairs(captured.fcts or {})do
   local info=debug.getinfo(fn,'S')
   assert(info.source=='@/mod/class/Actor.lua' and info.linedefined==6341 and info.lastlinedefined==6350,'unexpected preparation callback: '..info.source..':'..info.linedefined..'-'..info.lastlinedefined)
   fn() -- Native inscription bookkeeping. The allowlisted sustains have no inscription effect.
  end
  assert((not not a:isTalentActive(id))==req.active,'preparation skill did not change')
 end
 return json.object({operation=req.operation,action_id=req.action_id,actor_id=req.actor_id,talent_id=id,active=req.active})
end

function M.apply(state,world,req)
 assert(state._dm_items_world==world,'native inventory world mismatch')
 assert(type(req)=='table' and type(req.actor_id)=='string' and type(req.action_id)=='string','identity required')
 for k in pairs(req) do assert(({operation=true,action_id=true,actor_id=true,item_id=true,slot=true,position=true})[k],'unexpected loadout field') end
 assert(not require('native_inputs').has_pending(),'native input pending')
 local a=find_actor(state,req.actor_id)
 assert(not a.dead and not a.no_inventory_access and not require('rescue').is_down(a),'actor unavailable')
 assert(not a:attr('no_equipment_changes') and not (a:attr('sleep') and not a:attr('lucid_dreamer')),'native equipment locked')
 local signature=json.encode(req);state._dm_loadout_actions=state._dm_loadout_actions or {}
 local old=state._dm_loadout_actions[req.action_id]
 if old then assert(old.signature==signature,'action conflict');return old.receipt end
 if req.operation=='switch_set' then
  assert(req.item_id==nil and req.slot==nil and req.position==nil,'unexpected switch selection')
  a:quickSwitchWeapons(nil,nil,true)
  assert(not require('native_inputs').has_pending(),'native choice required')
  a._dm_active_weapon_set=a._dm_active_weapon_set=='backup' and 'main' or 'backup'
 else
  assert(req.operation=='equip' or req.operation=='unequip','unsupported loadout operation')
  assert(type(req.item_id)=='string','item identity required')
  local source,inven,pos,o,host=find_item(state,req.item_id)
  local ammo=o.slot=='QUIVER'
  assert(ammo or o:getNumber()==1,'stacked equipment requires native menu')
  if req.operation=='equip' then
   assert(inven==source.INVEN_INVEN,'item already worn')
   assert(not host,'item already attached')
   assert(type(req.slot)=='string','slot name required')
   local def=assert(a:getInvenDef(req.slot),'unknown inventory slot')
   assert(def.is_worn,'destination is not worn')
   local target=assert(a:getInven(def.id),'slot absent from native body')
   local slotpos=req.position or 1
   assert(type(slotpos)=='number' and slotpos==math.floor(slotpos) and slotpos>=1 and slotpos<=target.max,'invalid slot position')
   if o.is_tinker then
    assert(socket_allowed(a,target,slotpos),'socket unavailable')
    local base=assert(target[slotpos],'socket needs equipment')
    assert(base:canAttachTinker(o,true) and a:canUseTinker(o),'incompatible attachment')
    assert(a:doWearTinker(source:getInven(inven),pos,o,target,slotpos,base,true) and base.tinker==o,'native attachment rejected')
   else
    local permitted,reason=a:canWearObject(o,req.slot)
    assert(permitted,'native equipment requirement: '..tostring(reason))
    -- Native doWear handles requirements, replacement, two-handed conflicts,
    -- onWear callbacks, attached items, energy and returning replaced objects.
    a:doWear(source:getInven(inven),pos,o,source,target,slotpos)
    if ammo then
     local equipped=target[slotpos]
     local found=false
     if equipped then equipped:forAllStack(function(unit)if unit==o then found=true end end) end
     assert(found,'native ammo wear rejected')
    else
     local owner,now,idx,actual=find_item(state,req.item_id)
     assert(owner==a and now==def.id and idx==slotpos and actual==o,'native wear rejected')
    end
   end
  else
   assert(source==a and inven~=a.INVEN_INVEN and inven~=a.INVEN_SWIFT_HANDS,'item requires native management')
   if host then assert(a:doTakeoffTinker(host,o),'native detachment rejected')
   else a:doTakeoff(inven,pos,o,false) end
   local owner,now,_,actual=find_item(state,req.item_id)
   assert(owner==a and now==a.INVEN_INVEN and actual==o,'native takeoff rejected')
  end
  assert(not require('native_inputs').has_pending(),'native choice required')
 end
 local result=json.object({action_id=req.action_id,operation=req.operation,actor_id=req.actor_id,
   item_id=req.item_id or json.null,active_weapon_set=a._dm_active_weapon_set or 'main'})
 state._dm_loadout_actions[req.action_id]={signature=signature,receipt=result}
 return result
end
function M.inventory(a)
 local out=json.array()
 for slot,inv in pairs(a.inven or {}) do if type(slot)=='number' and type(inv)=='table' then
  local def=a.inven_def and a.inven_def[slot]
  if def then for pos,base in ipairs(inv) do base:forAllStack(function(o)
   local combat=o.combat or o.special_combat or {};local metrics=json.object({})
   for _,k in ipairs({'dam','apr','physcrit','physspeed','block'}) do if type(combat[k])=='number' then metrics[k]=combat[k] end end
   local ok,desc=pcall(function() return require('localization').description(tostring(o:getDesc({no_compare=true},nil,true,a)),o):gsub('#[%w_]+#','') end)
   out[#out+1]=json.object({item_id=o._dm_item_id or json.null,uid=o.uid,slot=def.short_name,pos=pos,
    name=tostring(o:getName{do_color=false}):gsub('#[%w_]+#',''),type=o.type or json.null,subtype=o.subtype or json.null,wear_slot=type(o.slot)=='string' and o.slot or json.null,
    is_tinker=o.is_tinker and true or false,imbued=o.been_imbued and true or false,relic_id=o._dm_relic_id or json.null,
    stack_uid=o.slot=='QUIVER' and base:getNumber()>1 and base.uid or nil,
    stack_count=o.slot=='QUIVER' and base:getNumber()>1 and base:getNumber() or nil,
    transmo_cents=slot==a.INVEN_INVEN and require('campaign_items').transmo_quote(a,o,
       not (o.slot=='QUIVER' and base==o and base:getNumber()>1)) or json.null,
    transmo_relic=not not (o._dm_relic_id or o.quest or o.plot),
    attachment=o.tinker and json.object({item_id=o.tinker._dm_item_id or json.null,uid=o.tinker.uid,
      name=tostring(o.tinker:getName{do_color=false}),image=o.tinker.image,type=o.tinker.type,subtype=o.tinker.subtype}) or json.null,
    description=ok and desc:gsub('#UID:[^#]+#',''):sub(1,12000) or '',metrics=metrics,stacked=base~=o or base:getNumber()~=1})
   assert(#out<=2000,'native inventory too large')
  end) end end
 end end
 table.sort(out,function(x,y)return x.uid<y.uid end)
 return out
end
local describe_inventory=require('localization').wrap(M.inventory)
function M.inventory(a)
 -- Native item tooltips may roll weapon damage when describing it for the wearer.
 local saved=rng.state_get()
 local ok,items=pcall(describe_inventory,a)
 rng.state_set(saved)
 if not ok then error(items,0) end
 return items
end
return M
