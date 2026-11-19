-- Formal scenario assembly. Refuse construction until both source-based
-- equipment and inscription modules are present and successfully applied.
local M={}
function M.create(logs)
 require('dm_progression').install()
 local Map=require 'engine.Map'
 local Party=require 'mod.class.Party'
 local learn_lore=Party.learnLore
 Party.learnLore=function(self,lore,_,silent,nostop,after_learn_cb,display_entity)
  return learn_lore(self,lore,true,silent,nostop,after_learn_cb,display_entity)
 end
 local roster=require 'formal_roster_data'
 local config=require 'encounter_config'
 if config then roster=require('encounter_roster').sources(config,roster) end
 local builder=require 'formal_roster'
 local factory=require 'formal_factory'
 local rescue=require 'rescue'
 local equipment=require 'formal_equipment'
 local inscriptions=require 'formal_inscriptions'
 world=require('mod.class.World').new()
 world:run()
 core.key={modState=function(k) assert(k=='ctrl'); return false end}
 game.party=Party.new{}
 local allies={}
 for i,source in ipairs(roster) do allies[i]=builder.create(source,i==1) end
 local p=allies[1]
 game.party:addMember(p,{main=true,type='player',control='full',orders={}})
 assert(game.party:setPlayer(p))
 game:setupDifficulty(2)
 if config and config.zone then require('native_zone').difficulty(config.zone) end
 game:setupPermadeath(p)
 local zone=factory.new_zone(config)
 local generated=require('formal_map').create(zone,p)
 local map,level=generated.map,generated.level
 map:setViewerActor(p)
 require('native_actions').install_visual_adapter(map)
 local spawn=generated.wide[1]
 for _,v in ipairs(generated.wide) do
  if math.max(math.abs(v.x-generated.entry.x),math.abs(v.y-generated.entry.y)) < math.max(math.abs(spawn.x-generated.entry.x),math.abs(spawn.y-generated.entry.y)) then spawn=v end
 end
 local positions={{x=spawn.x,y=spawn.y},{x=spawn.x-1,y=spawn.y},{x=spawn.x+1,y=spawn.y}}
 local differences={}
 local party_faction
 for i,actor in ipairs(allies) do
  if i>1 then
   actor.ai='improved_tactical'
   actor.ai_state={ai_move='move_complex',talent_in=1}
   -- Native birth resolvers must see their owner's actual party membership.
   game.party:addMember(actor,{type='ally',control='no',orders={}})
  end
  actor:resolve(); actor:resolve(nil,true)
  actor.native_source_faction=actor.faction
  if i==1 then party_faction=actor.faction end
  actor.faction=party_faction
  if config and config.party[i].birth then
   differences[i]={equipment=require('encounter_roster').equip(actor,config.party[i],zone,level)}
  else
   differences[i]={equipment=equipment.equip(actor,roster[i].id,zone,level),inscriptions=inscriptions.install(actor,roster[i].id,zone,level)}
   if config then require('encounter_roster').equip(actor,config.party[i],zone,level) end
  end
  actor.encounter_portrait=config and config.party[i].portrait
  if config and config.party[i].campaign_identity then
   actor._dm_world_id=config.party[i].campaign_identity.person_id
   actor._dm_origin=config.party[i].campaign_identity.origin
  end
  zone:addEntity(level,actor,'actor',positions[i].x,positions[i].y)
  assert(actor.level==roster[i].level,'source character level changed during placement')
  actor:resetToFull()
 end
 -- Birth resolvers can create native companions before their owner has map
 -- coordinates. Place those existing actors, not a second generated summon.
 for _,actor in ipairs(game.party.m_list)do
  if not actor.dead and not level:hasEntity(actor) then
   local owner=actor.summoner
   assert(owner and level:hasEntity(owner),'unplaced native companion has no owner')
   actor.native_source_faction=actor.faction;actor.faction=owner.faction
   local x,y=util.findFreeGrid(owner.x,owner.y,5,true,{[Map.ACTOR]=true})
   assert(x,'no space for native companion')
   zone:addEntity(level,actor,'actor',x,y)
   actor:updateModdableTile()
  end
 end
 local enemies,zone_population,native_prior
 if config and config.zone then
  native_prior={};for _,actor in pairs(level.entities)do native_prior[actor]=true end
  enemies,zone_population=require('native_zone').populate(zone,generated,p)
 else
 local enemy_count=config and #config.enemies or 5
 local selected=require('formal_map').enemy_positions(generated,spawn,enemy_count)
 local Astar=require 'engine.Astar'
 local astar=Astar.new(map,p)
 enemies={}
 for i,pos in ipairs(selected) do
  assert(astar:calc(spawn.x,spawn.y,pos.x,pos.y),'enemy location unreachable')
  local spec=config and config.enemies[i]
  enemies[i]=factory.add_rare(zone,level,spec and spec.level or rng.range(15,20),pos.x,pos.y,spec)
 end
 end
 for _,a in ipairs(allies) do
  for _,b in ipairs(allies) do assert(a:reactionToward(b)>=0,'party faction is hostile') end
  for _,foe in ipairs(enemies) do
   assert(a:reactionToward(foe)<0 and foe:reactionToward(a)<0,'rare faction is not mutually hostile')
  end
 end
 for i=2,#allies do assert(allies[i].__CLASSNAME=='mod.class.PartyMember' and allies[i].ai=='party_member' and allies[i].ai_state.ai_party=='improved_tactical','native party AI not installed') end
 -- Keep native equipment/body layer recipes. Only GPU drawing is omitted.
 Map.tiles.no_moddable_tiles=false
 for _,a in ipairs(allies) do a:updateModdableTile() end
 for _,a in ipairs(enemies) do a:updateModdableTile() end
 p.energy.value=game.energy_to_act
 local initial_turn=game.turn
 for _=1,10 do
  local tick=game.on_tick_end and next(game.on_tick_end.fcts)
  local custom=game.on_tick_end_custom and next(game.on_tick_end_custom.fcts)
  if not tick and not custom then break end
  game:onTickEndExecute()
 end
 assert(game.turn==initial_turn and p:enoughEnergy(),'initial callbacks advanced time or spent energy')
 assert(not (game.on_tick_end and next(game.on_tick_end.fcts)) and not (game.on_tick_end_custom and next(game.on_tick_end_custom.fcts)) and not next(game.__coroutines),'initial callbacks did not settle')
 if native_prior then
  enemies={}
  for _,actor in pairs(level.entities)do
   if not native_prior[actor] and actor.__CLASSNAME and actor.life and not actor._dm_vault_guardian then actor._dm_normal_population=true end
   if actor.__CLASSNAME and actor.life and actor~=p and actor.reactionToward and actor:reactionToward(p)<0 then enemies[#enemies+1]=actor end
  end
  table.sort(enemies,function(a,b)return a.uid<b.uid end)
 end
 game.paused=p:enoughEnergy() and true or false
 map.clean_fov=true
 p:doFOV()
 local state={game=game,player=p,enemy=enemies[1],allies=allies,enemies=enemies,map=map,Map=Map,logs=logs,visual_emit=map.particleEmitter,
  formal_differences=differences,formal_map_attempts=generated.attempts,zone_population=zone_population,campaign_bootstrap=config and config.purpose=='party_bootstrap' or false}
 rescue.bind_party(state)
 return state
end
return M
