-- Loaded by the isolated Wasm probe only. Use real inventory objects and native
-- wear hooks. A synthetic attachment exercises the base engine without DLC.
local json=require 'json_validate'
local M={}
function M.run(state,phase)
 local loadout=require 'campaign_loadout'
 local items=require 'campaign_items'
 if phase=='setup' then
  local area=require 'local_area'
  area.bind(state,{area_id='area:crew-probe',floor_count=1})
  area.enter(state,{area_id='area:crew-probe',floor=1,world_clock={world_tick=0,day_in_quarter=0}})
  if state.allies[1].T_BIND_DEMON then
   local a=state.allies[1]
   local native=assert(resolvers.resolveObject(a,{defined='TINKER_RAZOR_EDGE1',base_list='mod.class.Object:/data-orcs/general/objects/tinker.lua'},false,1))
   assert(a:addObject(a.INVEN_INVEN,native))
  end
  items.adopt(state,'probe-world','probe-campaign');state.game.paused=true
  local owner=state.allies[1]
  local weapon=assert(owner:getInven('MAINHAND')[1])
  local inherited,describe=rawget(weapon,'getDesc'),weapon.getDesc
  local inspected=false
  weapon.getDesc=function(self,...)
   rng.range(1,100);inspected=true
   return describe(self,...)
  end
  local cursor=rng.state_get().index
  loadout.inventory(owner)
  weapon.getDesc=inherited
  assert(inspected and rng.state_get().index==cursor,'inventory inspection advanced campaign RNG')
  return json.object({ready=true})
 end
 local a=assert(state.allies[1])
 local function slots()
  local result={}
  for _,slot in ipairs(loadout.slots(a)) do result[slot.slot..slot.pos]=slot end
  return result
 end
 local function apply(id,op,item,slot,pos)
  return loadout.apply(state,'probe-world',json.object({action_id=id,operation=op,actor_id=a._dm_world_id,item_id=item,slot=slot,position=pos}))
 end
 local function reconcile(id) items.reconcile(state,'probe-world','probe-site',id) end
 local main=a:getInven('MAINHAND')[1]
 local def=a:getInvenDef('MAINHAND')
 if phase=='demon_seed' then
  assert(a:learnTalent(a.T_DEMON_SEED,true,1))
  local t=a:getTalentFromId(a.T_DEMON_SEED)
  t.createSeed(a,t,assert(state.enemies[1]),true)
  items.adopt(state,'probe-world','probe-campaign')
 elseif phase=='demon_restore' then
  assert(slots().MAINHAND1.socket)
 end
 if phase=='demon_summon' then
  local seed=assert(main:getTinker());local demon=assert(seed.demon)
  assert(a:learnTalent(a.T_BIND_DEMON,true,1));a:incVim(100)
  assert(a:useTalent(a.T_BIND_DEMON,nil,nil,nil,a))
  assert(game.level:hasEntity(demon) and demon.summoner==a and demon.summon_time>0)
  assert(game.player==a)
  return json.object({demon=demon.uid,turns=demon.summon_time})
 end
 if phase=='demon_seed' or phase=='demon_restore' then
  local seed=assert(main:getTinker());local demon=assert(seed.demon)
  return json.object({uid=seed.uid,demon=demon.uid,name=demon.name,life=demon.life,level=demon.level})
 elseif phase=='socket_setup' then
  assert(main and main._dm_item_id and not main.tinker and not slots().MAINHAND1.socket)
  local part
  if a.T_BIND_DEMON then
   assert(a:learnTalent(a.T_DEMON_SEED,true,1))
   for i=1,5 do
    assert(a:learnTalent(a.T_BIND_DEMON,true,1))
    local s=slots()
    assert(s.MAINHAND1.socket and s.FINGER1.socket==(i>=2) and s.OFFHAND1.socket==(i>=3)
      and s.FINGER2.socket==(i>=4) and s.BODY1.socket==(i>=5))
   end
   for i=5,3,-1 do a:unlearnTalent(a.T_BIND_DEMON,1) end
   a.can_tinker.steamtech=1
   for _,o in ipairs(a:getInven('INVEN')) do if o.define_as=='TINKER_RAZOR_EDGE1' then part=o end end
   assert(part,'native attachment missing')
  else
   a.can_tinker={steamtech=1};a.tinker_restrict_slots={MAINHAND=1,FINGER=1}
   local Object=require 'mod.class.Object'
   part=Object.new{name='fixture attachment',type='tinker',subtype='steamtech',is_tinker='steamtech',on_slot=main.slot,material_level=1,object_tinker={wielder={combat_atk=2}}}
   assert(a:addObject(a.INVEN_INVEN,part))
  end
  assert(slots().MAINHAND1.socket and slots().FINGER1.socket and not slots().FINGER2.socket)
  items.adopt(state,'probe-world','probe-campaign')
  assert(loadout.attachments(state,a._dm_world_id,def.short_name,1)[1]==part._dm_item_id)
  apply('attach','equip',part._dm_item_id,def.short_name,1)
  assert(main:getTinker()==part)
  reconcile('after-attach')
  return json.object({uid=part.uid,item_id=part._dm_item_id})
 elseif phase=='drop_socket' then
  local part=assert(main:getTinker())
  apply('remove-base','unequip',main._dm_item_id)
  items.apply(state,'probe-world',json.object({action_id='ground-base',operation='remove',actor_id=a._dm_world_id,
   item_id=main._dm_item_id,destination=json.object({kind='world_location',id='probe-site'})}))
  reconcile('after-drop')
  assert(state._dm_ground_items[part._dm_item_id].attached)
  return json.object({item_id=main._dm_item_id})
 elseif phase=='recover_socket' then
  local id=state._dm_inventory_actions['ground-base'].receipt.item_id
  items.apply(state,'probe-world',json.object({action_id='recover-base',operation='add',actor_id=a._dm_world_id,item_id=id,source_location='probe-site'}))
  apply('rewear-base','equip',id,'MAINHAND',1)
  reconcile('after-pickup')
  return json.object({item_id=id})
 elseif phase=='socket_restore' then
  local part=assert(main:getTinker())
  local uid=part.uid
  assert(slots().MAINHAND1.socket and not slots().FINGER2.socket)
  apply('detach','unequip',part._dm_item_id)
  assert(not main:getTinker() and a:findInAllInventoriesByObject(part))
  reconcile('after-detach')
  local shield=assert(a:getInven('OFFHAND')[1]);assert(shield.subtype=='shield')
  assert(not a:canWearObject(shield,'MAINHAND'))
  a:learnTalent(a.T_STONESHIELD,true,1)
  assert(a:getObjectOffslot(shield)=='MAINHAND')
  apply('take-shield','unequip',shield._dm_item_id)
  local destinations=loadout.destinations(state,a._dm_world_id,shield._dm_item_id)
  assert(table.concat(destinations,',')=='OFFHAND,MAINHAND')
  apply('wear-shield','equip',shield._dm_item_id,'MAINHAND',1)
  assert(a:getInven('MAINHAND')[1]==shield)
  a:learnTalent(a.T_IMBUE_ITEM,true,1)
  assert(slots().BODY1.imbue and not slots().HEAD1.imbue)
  a:learnTalent(a.T_CRAFTY_HANDS,true,1)
  assert(slots().HEAD1.imbue and slots().BELT1.imbue and not slots().HANDS1.imbue)
  a:learnTalent(a.T_SWIFT_HANDS,true,1)
  assert(slots().SWIFT_HANDS4 and not slots().SWIFT_HANDS5)
  return json.object({uid=uid,shield=shield.uid,swift_hands=4})
 end
 error('unknown fixture phase')
end
return M
