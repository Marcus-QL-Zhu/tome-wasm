-- Source-based native births; formal_scene resolves equipment and placement.
local M={}
local function birth_context(actor,descriptors,defs,Birther)
 local birth=setmetatable({actor=actor,descriptors=descriptors,birth_descriptor_def=defs,descriptors_by_type={},all_classes={}},{__index=Birther})
 for _,d in ipairs(descriptors)do birth.descriptors_by_type[d.type]=d.name end
 -- Native mod.dialogs.Birther:isDescriptorAllowed decision order. The frozen
 -- descriptors are already current, so no desktop updateDescriptors is needed.
 function birth:isDescriptorAllowed(d,ignore)
  local result=true;ignore=ignore or {}
  for _,other in ipairs(descriptors)do
   if not ignore[d.type] then
    local choices=other.descriptor_choices and other.descriptor_choices[d.type]
    local choice=choices and (util.getval(choices[d.name],self) or util.getval(choices.__ALL__,self))
    if choice=='allow' then result=true
    elseif choice=='nolore' then result='nolore'
    elseif choice=='allow-nochange' then if not result then result=true end
    elseif choice=='never' or choice=='disallow' then result=false
    elseif choice=='forbid' then result=nil;break end
   end
  end
  if d.special_check and not d.special_check(self) then return nil end
  return result and not d.never_show
 end
 for _,d in ipairs(descriptors)do assert(birth:isDescriptorAllowed(d),'native birth combination denied: '..d.type..'.'..d.name)end
 -- Same native class/subclass order and descriptor data used by Birther's tree.
 -- Scenario injection does not depend on a human account's unlock flags.
 for _,parent in ipairs(defs.class or {})do
  if birth:isDescriptorAllowed(parent,{subclass=true}) then
   local row={id=parent.name,def=parent,nodes={}}
   local choices=parent.descriptor_choices and parent.descriptor_choices.subclass or {}
   for _,child in ipairs(defs.subclass or {})do
    local choice=util.getval(choices[child.name],birth)
    if (choice=='allow' or choice=='allow-nochange' or choice=='nolore') and birth:isDescriptorAllowed(child,{class=true,subclass=true}) then
     row.nodes[#row.nodes+1]={id=child.name,def=child,pid=parent.name}
    end
   end
   birth.all_classes[#birth.all_classes+1]=row
  end
 end
 return birth
end
function M.create(source, player)
 local policy=require 'content_policy'
 policy.check_class(source.subclass)
 for _,skill in ipairs(source.talents) do policy.check_talent(skill.id) end
 local Birther=require 'engine.Birther'
 local Actor=require(player and 'mod.class.Player' or 'mod.class.NPC')
 local actor=Actor.new{name=source.name,faction='allied-kingdoms'}
 if source.class=='Tinker' and not player then
  -- The native Tinker birth resolver adds two inventory shortcuts, even on NPCs.
  local keys=require 'engine.interface.PlayerHotkeys'
  Actor.addNewHotkey=Actor.addNewHotkey or keys.addNewHotkey
  keys.init(actor,{})
 end
 local defs=Birther.birth_descriptor_def
 local descriptors={}
 for _,v in ipairs({{'base','base'},{'world',"Maj'Eyal"},{'difficulty','Normal'},{'permadeath','Adventure'},{'sex',source.sex},{'race',source.race},{'subrace',source.subrace},{'class',source.class},{'subclass',source.subclass}}) do
  descriptors[#descriptors+1]=assert(defs[v[1]] and defs[v[1]][v[2]],v[1]..':'..v[2])
 end
 local birth=birth_context(actor,descriptors,defs,Birther)
 if source.subclass=='Adventurer' then policy.filter_wanderer_birth(birth,actor) end
 Birther.apply(birth,true)
 if source.source_mode=='native' or source.source_mode=='encounter' then
  -- A new character can be born in a high-tier zone. Use ToME's own
  -- birth-equipment resolver so the zone still supplies the class starter kit.
  for i,r in ipairs(actor) do
   if type(r)=='table' and r.__resolver=='equip' then actor[i]=resolvers.equipbirth(r[1]) end
  end
 end
 -- Campaign battles already have a location. The desktop campaign-start hook
 -- selects an intro zone once and has no role in a persistent squad member.
 actor.class_start_check=nil
 policy.check_actor(actor)
 if actor.custom_birthend then
  assert(source.class=='Adventurer' and source.subclass=='Wanderer','unsupported native custom birth finalization: '..source.subclass)
  local finished=false
  policy.filter_wanderer_birth(birth,actor)
  require('native_wanderer').makeWanderer({actor=actor,birth=birth,mode='random',finish=function()finished=true end})
  assert(finished and actor.randventurer_seed,'native Wanderer birth did not finish')
  actor.custom_birthend=nil
 end
 actor:forceLevelup(source.level)
 policy.check_actor(actor)
 for stat,value in pairs(source.stats) do actor:incStat(stat,value-actor:getStat(stat,nil,true,true)) end
 for _,skill in ipairs(source.talents) do
  local t=assert(actor:getTalentFromId(skill.id),skill.id)
  if not actor:knowTalentType(t.type[1]) then actor:learnTalentType(t.type[1],true) end
  actor:setTalentTypeMastery(t.type[1],skill.mastery)
  local current=actor:getTalentLevelRaw(skill.id)
  assert(current<=skill.rank,'birth talent exceeds source '..skill.id)
  if current<skill.rank then assert(actor:learnTalent(skill.id,true,skill.rank-current),skill.id) end
  assert(actor:getTalentLevelRaw(skill.id)==skill.rank,skill.id)
 end
 actor.formal_source_id=source.id
 policy.check_actor(actor)
 actor.formal_source_mode=source.source_mode
 return actor
end
-- Spend native player points using ToME's class allocation policy. Birth
-- already applied the race and class bonuses, so do not apply those twice.
function M.create_auto(source)
 local actor=M.create(source,false)
 local descriptor=require('engine.Birther').birth_descriptor_def.subclass[source.subclass]
 local stats,categories,unknown={},{},{}
 local keys=table.keys(descriptor.stats or {});table.sort(keys)
 for _,stat in ipairs(keys)do
  for _=1,descriptor.stats[stat]do stats[#stats+1]=actor.stats_def[stat].id end
 end
 for category,known in pairs(actor.talents_types)do
  local entry={tt=category,rarity=1}
  categories[category]=entry
  if not known then unknown[#unknown+1]=entry end
 end
 table.sort(unknown,function(a,b)return a.tt<b.tt end)
 local previous=actor.no_points_on_levelup
 actor.no_points_on_levelup=true
 actor:levelupClass({class=source.subclass,initialized=true,use_actor_points=true,auto_stats=stats,
  ttypes=categories,unknown_tt=unknown,level_by_class=true,check_talents_level=true})
 actor.no_points_on_levelup=previous
 require('content_policy').check_actor(actor)
 return actor
end

function M.ensure_basic_equipment(actor)
 local native=resolvers
 local weapons={Bulwark='longsword',Berserker='battleaxe',Archer='longbow',Rogue='dagger',Cursed='battleaxe'}
 local class=actor.descriptor.subclass
 -- Remember only the birth kit's slot types. Rehiring rolls new items of those types.
 local kit=actor._dm_birth_kit
 if not kit then
  kit={}
  for _,slot in ipairs({'MAINHAND','OFFHAND','QUIVER','BODY','HANDS'})do
   local inv=actor:getInven(slot)
   local spec=inv and (inv[1] or inv.auto_equip_filter)
   if spec and type(spec.type)=='string' and type(spec.subtype)=='string' then
    kit[slot]={type=spec.type,subtype=spec.subtype}
   end
  end
  if class=='Brawler' then
   kit.HANDS=kit.HANDS or {type='armor',subtype='hands'}
  else
   kit.MAINHAND=kit.MAINHAND or {type='weapon',subtype=weapons[class] or 'longsword'}
  end
  kit.BODY=kit.BODY or {type='armor',subtype='cloth'}
  if class=='Archer' then kit.QUIVER=kit.QUIVER or {type='ammo',subtype='arrow'} end
  actor._dm_birth_kit=kit
 end
 for _,slot in ipairs({'MAINHAND','OFFHAND','QUIVER','BODY','HANDS'})do
  local spec=kit[slot]
  if spec and #actor:getInven(slot)==0 then
   if spec.type=='alchemist-gem' then
    local talent=actor:getTalentFromId(actor.T_CREATE_ALCHEMIST_GEMS)
    actor:wearObject(talent.make_gem(actor,talent,'GEM_AGATE'),false,false,actor:getInven(slot))
   else
    local filter={type=spec.type,subtype=spec.subtype,no_unique=true,ego_chance=-1000,autoreq=false,max_ood=0,ignore_material_restriction=true}
    if spec.subtype=='steamsaw' or spec.subtype=='steamgun' then
     filter.base_list='mod.class.Object:/data-orcs/general/objects/'..spec.subtype..'.lua'
    end
    for _=1,10 do
     local item=native.resolveObject(actor,filter,false,1)
     if item and actor:wearObject(item,false,false,actor:getInven(slot)) then break end
    end
   end
  end
 end
 local weapon_slot=class=='Brawler' and 'HANDS' or 'MAINHAND'
 assert(#actor:getInven('BODY')>0 and #actor:getInven(weapon_slot)>0,'native basic equipment unavailable')
 if kit.QUIVER then assert(#actor:getInven('QUIVER')>0,'native ammunition unavailable') end
end

function M.equip_auto(actor)
 actor:resolve();actor:resolve(nil,true)
 M.ensure_basic_equipment(actor)
end
return M
