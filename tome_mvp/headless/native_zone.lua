-- Native Zone ecology and difficulty. Terrain layout remains formal_map's job.
local M={}
local templates={forest='old-forest',dungeon='ruins-kor-pul',cave='trollmire'}
local bound_zone=setmetatable({},{__mode='k'})
function M.is_temporary(zone)
 return zone and zone.no_planechange==true and
  ((zone.short_name=='demon-plane-spell' and zone.is_demon_plane==true) or
   (zone.short_name=='dreamscape-talent' and zone.is_dream_scape==true))
end
function M.install_loading_adapter()
 if core.noise and game and game.uiset and not game.uiset.setupMinimap then
  game.uiset.setupMinimap=function()end
 end
 if M._loading_adapter or not core.noise then return end
 M._loading_adapter=true
 -- Local profile facts already live in the campaign VM. Desktop account
 -- persistence is absent, including when a native plane awards its lore.
 profile.saveModuleProfile=profile.saveModuleProfile or function() return true end
 -- Native save lookup has no desktop archive in the browser. Persistent
 -- campaign areas are restored by the partition reader.
 savefile_pipe.doLoad=savefile_pipe.doLoad or function(_,_,kind) assert(kind=='zone');return nil end
 local Dialog=require 'engine.ui.Dialog'
 local waiter=Dialog.simpleWaiterTip
 Dialog.simpleWaiterTip=function(self,...)
  if debug.getinfo(2,'S').source=='@/engine/Zone.lua' then return {done=function()end} end
  return waiter(self,...)
 end
 local redraw=core.display.forceRedraw
 core.display.forceRedraw=function(...)
  if debug.getinfo(2,'S').source=='@/engine/Zone.lua' then return end
  return assert(redraw,'unavailable desktop redraw')(...)
 end
 local Zone=require 'mod.class.Zone'
 local get_level=Zone.getLevel
 Zone.getLevel=function(self,...)
  local level,created=get_level(self,...)
  if M.is_temporary(self) and level and level.map then require('headless_visuals').install_map(level.map) end
  return level,created
 end
end
function M.install_runtime()
 if M._runtime_installed then return end
 M._runtime_installed=true
 M.install_loading_adapter()
 local lore=require 'mod.class.interface.PartyLore'
 if not next(lore.lore_defs)then lore:loadDefinition('/data/lore/lore.lua')end
 local NPC=require 'mod.class.NPC'
 local add=NPC.addTemporaryValue
 local retaliation=setmetatable({},{__mode='k'})
 NPC.addTemporaryValue=function(actor,prop,value,...)
  local id=add(actor,prop,value,...)
  if prop=='on_melee_hit' then
   retaliation[actor]=retaliation[actor]or {};retaliation[actor][id]=true
  end
  return id
 end
 headless_before_retal_clear=function(actor)
  -- The native low-level Rare rule discards all current retaliation. Discard
  -- those exact old offsets too, so later sustain/equipment removal cannot
  -- subtract them from retaliation installed after this generation point.
  for id in pairs(retaliation[actor]or {})do
   if actor.compute_vals and actor.compute_vals[id]then actor.compute_vals[id]={}end
  end
 end
 headless_before_troll_damage_clear=function(actor)
  -- This one native unique replaces its entire inc_damage table on entry.
  -- Retire only the equipment offsets that assignment is about to erase.
  for inv_id,inv in pairs(actor.inven or {})do
   if actor.inven_def[inv_id] and actor.inven_def[inv_id].is_worn then
    for _,item in ipairs(inv)do
     local id=item.wielded and item.wielded.inc_damage
     if id and actor.compute_vals and type(actor.compute_vals[id])=='table' then
      if benchmark_troll_damage_reset then benchmark_troll_damage_reset(actor,item,id,actor.compute_vals[id])end
      actor.compute_vals[id]={}
     end
    end
   end
  end
 end
 if not fs.open then
  local grammars=require 'native_name_grammars'
  fs.open=function(path,mode)
   assert(mode=='r' and grammars[path],'unsupported native text read '..tostring(path))
   local text,offset=grammars[path],1
   return {readLine=function()
    if offset>#text then return nil end
    local first,last=text:find('\n',offset,true)
    local line=text:sub(offset,first and first-1 or #text):gsub('\r$','')
    offset=last and last+1 or #text+1
    return line
   end,close=function()offset=#text+1 end}
  end
 end
end
function M.ensure_campaign()
 M.install_runtime()
 assert(game and game.state and game.player and game.player.descriptor,'incomplete native campaign')
 if game.state._project_nightmare_ready then
  assert(game.difficulty==3 and game.player.descriptor.difficulty=='Nightmare','inconsistent saved difficulty')
  return
 end
 assert(game.difficulty==2 and game.player.descriptor.difficulty=='Normal','unknown baseline difficulty')
 local defs=require('engine.Birther').birth_descriptor_def
 -- Same table copy as native Birther:applyGameState, without a birth dialog.
 for _,descriptor in ipairs({assert(defs.base.base),assert(defs.difficulty.Nightmare)})do
  assert(not descriptor.game_state_execute,'unexpected difficulty birth script')
  table.merge(game.state.birth,table.clone(descriptor.game_state,true),true)
 end
 game:setupDifficulty(3)
 game.player.descriptor.difficulty='Nightmare'
 game.state._project_nightmare_ready=true
end
function M.difficulty(config) M.ensure_campaign() end
function M.bind_zone(zone)
 local adjust=assert(zone._project_actor_adjust_base,'missing native actor adjust')
 local prior=assert(zone._project_post_filter_base,'missing native post filter')
 local policy=require 'content_policy'
 zone.actor_adjust_level=function(z,level,actor)
  if actor.formal_source_id or (game.party and game.party:hasMember(actor))then return actor.level end
  return adjust(z,level,actor)
 end
 zone.post_filter=function(z,level,kind,entity,filter)
  if kind=='actor' and filter and (filter.random_elite or filter.random_boss)then
   local copy=table.clone(filter);local class_filter=copy.class_filter
   copy.class_filter=function(d,a)return policy.allowed_class(d.name) and (not class_filter or class_filter(d,a))end
   filter=copy
  end
  return prior(z,level,kind,entity,filter)
 end
 bound_zone[zone]={actor=zone.actor_adjust_level,post=zone.post_filter}
end
function M.is_bound_zone(zone)
 local b=bound_zone[zone]
 return b~=nil and rawget(zone,'actor_adjust_level')==b.actor and rawget(zone,'post_filter')==b.post
end
function M.set_loot_reference(zone,level)
 assert(type(level)=='number' and level>=1 and level<=150 and level==math.floor(level),'invalid loot reference level')
 local maximum=math.min(5,math.ceil(level/10))
 zone.min_material_level=math.max(1,maximum-1)
 zone.max_material_level=maximum
end

function M.configure(zone,config)
 assert(not zone._project_reference_level and not zone._project_actor_adjust_base and not zone._project_post_filter_base,'native zone already configured')
 local r=assert(config.reference_level,'missing Zone reference level')
 assert(type(r)=='number' and r>=1 and r<=150 and r==math.floor(r),'invalid Zone reference level')
 local floors=config.floor_count or 1
 assert(type(floors)=='number' and floors==math.floor(floors) and floors>=1 and floors<=20,'invalid floor count')
 zone.level_range={r,r};zone.level_scheme='fixed';zone.max_level=floors
 zone._project_actor_adjust_base=assert(zone.actor_adjust_level)
 zone._project_post_filter_base=assert(zone.post_filter)
 -- Do not use fixed guardians or final-floor scripted boss maps.
 zone.levels={};zone.generator.actor=table.clone(assert(zone.generator.actor),true)
 for key in pairs(zone.generator.actor)do
  if key:find('guardian',1,true)then zone.generator.actor[key]=nil end
 end
 zone._project_reference_level=r
 if config.loot_reference_level~=nil then M.set_loot_reference(zone,config.loot_reference_level) end
 M.bind_zone(zone)
end
function M.template(config,kind)
 local name=config.template or templates[kind]
 assert(name=='old-forest' or name=='ruins-kor-pul' or name=='trollmire','unsupported native Zone ecology')
 return name
end
function M.populate(zone,generated,player,refresh)
 local level,map=generated.level,generated.map
 if level.vaults_list then
  for x=0,map.w-1 do for y=0,map.h-1 do
   local queued=map.room_map[x][y].add_entities
   if queued then
    for _,entry in ipairs(queued)do
     local kind,entity=entry[1],entry[2]
     if kind=='object' then entity._dm_vault_loot=true end
     if kind=='actor' then entity._dm_vault_guardian=true end
     local original={}
     for key,value in pairs(entry.elists or {})do original[key]=zone[key];zone[key]=value end
     zone:addEntity(level,entity,kind,x,y,true)
     for key,value in pairs(original)do zone[key]=value end
    end
    map.room_map[x][y].add_entities=nil
   end
  end end
 end
 local existing={}
 for _,actor in pairs(level.entities)do existing[actor]=true end
 -- Native Zone:newLevel applies ambient lighting before actor generation.
 -- This lights terrain; it does not explore it or reveal actors through walls.
 if zone.all_lited and not refresh then map:liteAll(0,0,map.w,map.h)end
 level.spots=generated.spots or {}
 level.data.generator={actor=table.clone(zone.generator.actor,true)}
 local data=level.data.generator.actor
 assert(not data.guardian,'fixed Zone guardian must be disabled')
 local policy=require 'content_policy'
 policy.filter_random_boss_talents()
 local generator=require(data.class).new(zone,map,level,level.spots)
 local prior=rawget(zone,'makeEntity')
 local make=zone.makeEntity
 zone.makeEntity=function(z,target,kind,filter,force_level,prob_filter)
  local entity=make(z,target,kind,filter,force_level,prob_filter)
  if entity and kind=='actor' and target==level then policy.check_actor(entity) end
  return entity
 end
 local generate_one=generator.generateOne
 generator.generateOne=function(gen)
  local _,reason=policy.draw_actor(level,function()generate_one(gen)end)
  if reason then print('Skipped native population slot after repeated policy denials:',reason) end
 end
 local ok,err=xpcall(function()generator:generate()end,debug.traceback)
 rawset(zone,'makeEntity',prior)
 if not ok then error(err,0) end
 for _,actor in pairs(level.entities)do
  if not existing[actor] and actor.__CLASSNAME and actor.life then actor._dm_normal_population=true end
 end
 local enemies={}
 for _,actor in pairs(level.entities)do
  if actor.__CLASSNAME and actor.life and actor~=player and actor:reactionToward(player)<0 then
   policy.check_actor(actor);enemies[#enemies+1]=actor
  end
 end
 table.sort(enemies,function(a,b)return a.uid<b.uid end)
 assert(#enemies>0,'native Zone generated no hostile actors')
 return enemies,{
  template=zone.short_name,reference_level=zone._project_reference_level,
  adjusted_base_level=zone.base_level,difficulty='Nightmare',fixed_guardian=false,
  rare_chance_denominator=generator.randelite,random_boss_chance_denominator=generator.randboss,
  talent_multiplier=game.state.birth.difficulty_talent_mult,
  native_population=true,native_original_layout=false,
  ambient_light=not not zone.all_lited,
 }
end
return M
