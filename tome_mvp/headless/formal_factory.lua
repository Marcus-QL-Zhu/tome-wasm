-- Official ToME zone and random_elite factory, for the isolated formal scenario.
local M={}
local bound_lists=setmetatable({},{__mode='k'})
-- Rebind this reviewed host closure after native deserialization: Lua bytecode
-- alone does not capture its configuration or class upvalues.
function M.bind_formal_lists(z,config)
 local NPC=require 'mod.class.NPC'
 local Object=require 'mod.class.Object'
 local Grid=require 'mod.class.Grid'
 z.embed_lists=function(z)
  local paths,seen={},{}
  for _,spec in ipairs(config and config.enemies or {{}}) do
   local source=spec.source or 'orc'
   if not seen[source] then paths[#paths+1]='/data/general/npcs/'..source..'.lua';seen[source]=true end
  end
  z.npc_list=NPC:loadList(paths)
  z.grid_list=Grid:loadList('/data/general/grids/basic.lua')
  local map_kind=config and config.map and config.map.kind
  if map_kind=='forest' or map_kind=='town' then
   local outdoors=Grid:loadList('/data/general/grids/forest.lua')
   for k,v in pairs(outdoors)do if type(k)=='string' and z.grid_list[k]==nil then z.grid_list[k]=v end end
  end
  z.object_list=Object:loadList('/data/general/objects/objects.lua')
  z.trap_list={}
 end
 bound_lists[z]=z.embed_lists
end
function M.is_bound_formal_lists(z) return bound_lists[z]~=nil and rawget(z,'embed_lists')==bound_lists[z] end
function M.new_zone(config)
 local Zone=require 'mod.class.Zone'
 local NPC=require 'mod.class.NPC'
 local Object=require 'mod.class.Object'
 local Grid=require 'mod.class.Grid'
 M.install_object_resolver()











 savefile_pipe.doLoad=function(_,_,kind) assert(kind=='zone'); return nil end
 Zone:setup{npc_class='mod.class.NPC',grid_class='mod.class.Grid',object_class='mod.class.Object',trap_class='mod.class.Trap',on_setup=function(z)
  if config and config.zone then require('native_zone').configure(z,config.zone) end
  game:applyDifficulty(z)
 end}
 Zone.check_filter=function(...) return game.state:entityFilter(...) end
 Zone.default_prob_filter=true
 Zone.default_filter=function(...) return game.state:defaultEntityFilter(...) end
 Zone.alter_filter=function(...) return game.state:entityFilterAlter(...) end
 Zone.post_filter=function(...) return game.state:entityFilterPost(...) end
 Zone.ego_filter=function(...) return game.state:egoFilter(...) end
 if config and config.zone then
  local zone=Zone.new(require('native_zone').template(config.zone,config.map.kind))
  for _,path in ipairs({'/data/general/grids/basic.lua','/data/general/grids/forest.lua'})do
   for key,value in pairs(Grid:loadList(path))do
    if type(key)=='string' and not zone.grid_list[key]then zone.grid_list[key]=value end
   end
  end
  game.zone=zone
  return zone
 end
 local zone=Zone.new('formal-squad',{
  name='Formal squad',max_level=1,level_range={16,16},level_scheme='fixed',width=64,height=64,
  min_material_level=2,max_material_level=3,
  actor_adjust_level=function(_,_,entity)
   if entity.formal_source_id then return entity.level end
   if entity.randboss and entity.level_range then return entity.level_range[1] end
   return entity.level
  end,
  embed_lists=function(z) M.bind_formal_lists(z,config); return z:embed_lists() end,
 })
 M.bind_formal_lists(zone,config)
 game.zone=zone
 return zone
end
-- Keep the saved Zone callbacks above at their original source lines.
local fallback_careers={Bulwark=true,Archmage=true,Summoner=true,Mindslayer=true}
function M.add_rare(zone,level,lev,x,y,spec)
 assert(lev>=1 and lev<=50 and lev==math.floor(lev))
 spec=spec or {prototype='orc warrior',class='Bulwark',hp_multiplier=2}
 local policy=require 'content_policy'
 if spec.class then policy.check_class(spec.class) end
 for _,skill in ipairs(spec.talents or {}) do policy.check_talent(skill.id) end
 policy.filter_random_boss_talents()
 local rare=spec.kind~='native'
 local filter={name=spec.prototype}
 if rare then filter.random_elite={level=lev};filter.class_filter=function(d)return policy.allowed_class(d.name) and (not spec.class or d.name==spec.class) end end
 local use_fallback=false
 local function place()
  local actor=assert(zone:makeEntity(level,'actor',filter,lev,true),'native entity generation failed')
  policy.check_actor(actor)
  if use_fallback then
   local class=actor.descriptor and actor.descriptor.classes and actor.descriptor.classes[1]
   assert(fallback_careers[class],'no compatible fallback career for native Rare')
  end
  -- Encounter roles are separate from a template's ancestral faction.
  actor.native_source_faction=actor.faction;actor.faction='enemies'
  if rare then assert(actor.randboss and actor.rank==3.2,'not a native rare')
  elseif actor.level<lev then actor:forceLevelup(lev) end
  zone:addEntity(level,actor,'actor',x,y)
  policy.check_actor(actor)
  return actor
 end
 local actor,reason
 if rare or not spec.prototype then
  actor,reason=policy.draw_actor(level,place)
  if reason and rare and not spec.class then
   use_fallback=true
   filter.class_filter=function(d)return fallback_careers[d.name] end
   actor,reason=policy.draw_actor(level,place,1)
  end
  assert(actor,'random enemy draws exhausted: '..tostring(reason))
 else
  actor=place()
 end
 assert(actor.level==lev,'incorrect generated level')
 assert(not actor._formal_life_doubled,'rare life already doubled')
 for _,skill in ipairs(spec.talents or {}) do
  local t=assert(actor:getTalentFromId(skill.id),'unknown native enemy talent')
  actor:learnTalentType(t.type[1],true);actor:setTalentTypeMastery(t.type[1],skill.mastery or 1)
  local rank=actor:getTalentLevelRaw(skill.id)
  assert(rank<=skill.rank,'generated enemy rank exceeds requested rank')
  if rank<skill.rank then assert(actor:learnTalent(skill.id,true,skill.rank-rank)) end
 end
 actor.max_life=actor.max_life*(spec.hp_multiplier or (rare and 2 or 1))
 actor._formal_life_doubled=true
 actor:resetToFull()
 policy.check_actor(actor)
 return actor
end
function M.install_object_resolver()
 local Object=require 'mod.class.Object'
 -- The upstream wild infusion resolver reads a sibling that otherwise may not
 -- yet have been resolved during Lua's unordered table traversal.
 if not Object._headless_resolve_installed then
 local resolve=Object.resolve
 function Object:resolve(t,last,on_entity,key_chain)
  if (not t or t==self) and self.name=='wild infusion' and type(self.chance)=='table' and self.chance.__resolver=='mbonus_level' then
   self.chance=resolvers.calc.mbonus_level(self.chance,self,self,self,'chance',{})
  end
  return resolve(self,t,last,on_entity,key_chain)
 end
 Object._headless_resolve_installed=true
 end
end
return M
