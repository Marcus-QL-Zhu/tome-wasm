-- Experimental same-VM continuation. Refuses unsupported actor relationships.
local M={}
function M.apply(state,spec)
 assert(not next(state._dm_world_person_index or {}),'bound world persons require persistent area transitions')
 local game=state.game
 local Map=state.Map
 assert(#state.allies>=1 and #state.allies<=3 and #game.party.m_list==#state.allies,'unsupported party or auxiliary bodies')
 assert(not next(game.__coroutines),'coroutines active')
 local old=game.level
 local oldzone=game.zone
 local original_turn=game.turn
 assert(not (game.on_tick_end and next(game.on_tick_end.fcts)) and not (game.on_tick_end_custom and next(game.on_tick_end_custom.fcts)),'callbacks require explicit settlement')
 assert(not next(game.__coroutines) and not require('native_inputs').has_pending() and not require('rule_events').has_pending(),'callback requires continuation')
 if not state._dm_wipeout then for _,foe in ipairs(state.enemies) do assert(foe.dead,'callback revived enemy') end end
 assert(game.turn==original_turn,'callback advanced turn')
 local party={};for _,a in ipairs(state.allies) do party[a]=true end
 for _,a in ipairs(state.allies) do
  assert(a._dm_world_id and a._dm_origin and not a.dead and not require('rescue').is_down(a),'unbound or down party member')
  assert(not a.summoner,'unsupported summon')
  for _,effect in pairs(a.tmp or {}) do
   if type(effect)=='table' then for key,value in pairs(effect) do
    assert(value~=old and value~=old.map and value~=oldzone,'effect references old scene')
    if type(value)=='table' and value.uid and old.entities[value.uid]==value and not party[value] then
     assert(key=='src' and value.dead,'effect references old entity')
    end
   end end
  end
  assert(old:hasEntity(a)==a and old.map(a.x,a.y,Map.ACTOR)==a,'old actor registration mismatch')
 end
 for _,a in pairs(old.entities) do
  if a.__CLASSNAME and a.__CLASSNAME:find('Projectile',1,true) then error('projectile active') end
 end
 assert(not game._chronoworlds,'unsupported timeline')
 game.party:leftLevel(false)
 assert(#game.party.m_list==#state.allies and game.player==state.player,'party control changed on leave')
 if oldzone.on_leave then local _,_,stop=oldzone.on_leave(1,-1000,'formal-squad');assert(not stop,'zone refused leave') end
 state.player:onLeaveLevel(oldzone,old)
 require('campaign_items').detach_ground(state)
 game:leaveLevel(old,1,-1000)
 assert(game.turn==original_turn,'leave advanced turn')
 -- This scene uses a synthetic fixed zone name. Discard only that zone's
 -- native last-persist cache so the new encounter loads its own NPC sources.
 require('mod.class.Zone'):removeLastPersistZone('formal-squad')
 local factory=require 'formal_factory'
 local zone=factory.new_zone(spec)
 local generated=require('formal_map').create(zone,state.player,spec)
 local map,level=generated.map,generated.level
 map:setViewerActor(state.player)
 require('native_actions').install_visual_adapter(map)
 local spawn=generated.wide[1]
 for _,v in ipairs(generated.wide) do
  if math.max(math.abs(v.x-generated.entry.x),math.abs(v.y-generated.entry.y)) < math.max(math.abs(spawn.x-generated.entry.x),math.abs(spawn.y-generated.entry.y)) then spawn=v end
 end
 local positions={{x=spawn.x,y=spawn.y},{x=spawn.x-1,y=spawn.y},{x=spawn.x+1,y=spawn.y}}
 for i,a in ipairs(state.allies) do
  assert(not old:hasEntity(a),'native leave retained actor')
  a.x=nil;a.y=nil;a.fov=nil;a.can_see_cache=nil;a.ai_target={}
  a.fov_computed=nil;a.fov_last_x=nil;a.fov_last_y=nil
  if a.ai_state then a.ai_state.tactic_leash_anchor=nil;a.ai_state.path=nil end
  a:move(positions[i].x,positions[i].y,true)
  level:addEntity(a)
  assert(level:hasEntity(a)==a and not old:hasEntity(a) and map(a.x,a.y,Map.ACTOR)==a,'new actor registration mismatch')
 end
 local retired={}
 for _,entity in pairs(old.entities) do retired[#retired+1]=entity end
 table.sort(retired,function(a,b)return a.uid<b.uid end)
 for _,entity in ipairs(retired) do old:removeEntity(entity) end
 local selected=require('formal_map').enemy_positions(generated,spawn,#spec.enemies)
 local astar=require('engine.Astar').new(map,state.player)
 local enemies={}
 for i,pos in ipairs(selected) do
  assert(astar:calc(spawn.x,spawn.y,pos.x,pos.y),'enemy location unreachable')
  enemies[i]=factory.add_rare(zone,level,spec.enemies[i].level,pos.x,pos.y,spec.enemies[i])
 end
 state.map=map;state.enemies=enemies;state.enemy=enemies[1];state.visual_emit=map.particleEmitter
 state.terrain_memory={};state.navigation_memory={};state.visible={};state.shared_seen={}
 state.last_action=nil;state.resolutions={};state.campaign_bootstrap=false;state._dm_wipeout=nil
 if zone.on_enter then zone.on_enter(1,-1000,oldzone) end
 state.player:onEnterLevel(zone,level)
 for _,actor in pairs(level.entities) do if actor.removeEffectsFilter then actor:removeEffectsFilter(actor,function(e)return e.zone_wide_effect end,nil,nil,true) end end
 assert(game.turn==original_turn,'entry advanced turn')
 map.clean_fov=true;state.player:doFOV()
 return require('json_validate').object({party_count=#state.allies,enemy_count=#enemies,turn=game.turn})
end
return M
