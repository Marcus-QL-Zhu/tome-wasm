-- Single-scene content boundary. IDs come from the installed ToME 1.7.6 rules.
local M={}
local denied={T_REVISIONIST_HISTORY=true,T_REVISIONIST_HISTORY_BACK=true,T_SEE_THE_THREADS=true,T_CEASE_TO_EXIST=true,T_PARADOX_CLONE=true,T_TEMPORAL_REPRIEVE=true,
 T_PROJECTION=true,T_OVER_MIND=true,T_AMBUSCADE=true,T_MECHARACHNID_PILOTING=true}
local planes={T_DREAMSCAPE=true,T_DEMON_PLANE=true}
local manual_plane_actor
function M.bind_plane_control(is_manual) manual_plane_actor=is_manual end
function M.plane_player(actor)
 return manual_plane_actor and manual_plane_actor(actor) or false
end
local function plane_cast_allowed(actor,id)
 if not planes[id] then return true end
 if not core.noise then return false end
 if actor:isTalentActive(id) then return true end -- Native Fearscape teardown.
 if game.party:hasMember(actor) then return M.plane_player(actor) end
 return id=='T_DEMON_PLANE'
end
local max_actor_draws=8
local active_draw
local function reject(message,actor)
 if active_draw and (not actor or (actor.uid and actor.uid>=active_draw.first_uid)) then
  error({draw=active_draw,message=message},0)
 end
 error(message,3)
end
function M.allowed_class(name) return name~='Paradox Mage' and name~='Temporal Warden' end
function M.allowed_talent(id)
 if type(id)~='string' or denied[id] or (planes[id] and not core.noise) then return false end
 local t=require('engine.interface.ActorTalents').talents_def[id]
 return not (t and t.type and t.type[1]:match('^chronomancy/'))
end
function M.check_class(name,actor)
 if not M.allowed_class(name) then reject('content policy rejects class: '..tostring(name),actor) end
end
function M.check_talent(id,actor)
 assert(type(id)=='string','content policy rejects talent: '..tostring(id))
 if not M.allowed_talent(id) then reject('content policy rejects talent: '..id,actor) end
 local defs=require('engine.interface.ActorTalents').talents_def
 assert(defs[id], 'unknown native talent: '..tostring(id))
 return true
end
function M.check_actor(actor)
 local descriptor=actor.descriptor or {}
 if descriptor.subclass then M.check_class(descriptor.subclass,actor) end
 for _,name in ipairs(descriptor.classes or {}) do M.check_class(name,actor) end
 for _,entry in ipairs(actor.auto_classes or {}) do if entry.class then M.check_class(entry.class,actor) end end
 for tree,unlocked in pairs(actor.talents_types or {}) do
  if unlocked and tree:match('^chronomancy/') then reject('content policy rejects talent tree: '..tree,actor) end
 end
 for id,rank in pairs(actor.talents or {}) do
  if type(rank)=='number' and rank>0 then M.check_talent(id,actor) end
 end
 for id,rank in pairs(actor.learn_tids or {}) do
  if type(rank)=='number' and rank>0 then M.check_talent(id,actor) end
 end
end
-- Keep the native placement and level-up order. A policy denial discards the
-- new entities, their unique registrations, and their pending tick callbacks.
function M.draw_actor(level,place,limit)
 local previous_draw=active_draw
 local g=game
 local player,turn=g.player,g.turn
 local parent_callbacks=g.on_tick_end_custom
 local pending=parent_callbacks or g.on_tick_end
 local uniques=g.uniques
 local before=table.clone(uniques)
 local spots={}
 for _,spot in ipairs(level.spots or {}) do spots[spot]=spot.spawned_actors or false end
 local uid=require('engine.Entity').native_uid_state
 local reason
 for _=1,limit or max_actor_draws do
  local draw,callbacks={first_uid=uid()},{}
  g:onTickEndCapture(callbacks)
  if pending then callbacks.names=table.clone(pending.names) end
  active_draw=draw
  local ok,result=xpcall(function()
   local actor=place()
   for _,entity in ipairs(level.e_array) do
    if entity.uid>=draw.first_uid and entity.life then M.check_actor(entity) end
   end
   return actor
  end,debug.traceback)
  active_draw=previous_draw
  g.on_tick_end_custom=parent_callbacks
  if ok then
   if #callbacks.fcts>0 then g:onTickEndMerge(callbacks) end
   return result
  end
  if type(result)~='table' or result.draw~=draw then error(result,0) end
  assert(g.level==level and g.player==player and g.turn==turn and not require('rule_events').has_pending(),
   'rejected enemy changed the generation boundary')
  for i=#level.e_array,1,-1 do
   local entity=level.e_array[i]
   if entity.uid>=draw.first_uid then
    assert(not g.party:hasMember(entity),'rejected enemy changed the party')
    level:removeEntity(entity,true)
   end
  end
  for spot,count in pairs(spots) do spot.spawned_actors=count or nil end
  for key in pairs(uniques) do uniques[key]=before[key] end
  for key,value in pairs(before) do uniques[key]=value end
  reason=result.message
 end
 return nil,reason
end
-- GameState:applyRandomClass respects not_on_random_boss when building its
-- talent choices. Non-chronomancy trees retain all other legal talents.
function M.filter_random_boss_talents()
 local subclasses=require('engine.Birther').birth_descriptor_def.subclass
 for _,descriptor in ipairs(subclasses)do
  if not M.allowed_class(descriptor.name)then descriptor.not_on_random_boss=true end
 end
 local defs=require('engine.interface.ActorTalents').talents_def
 for id,t in pairs(defs) do if type(id)=='string' and not M.allowed_talent(id) then t.not_on_random_boss=true end end
end
-- Wanderer randomly gains whole trees. Exclude only trees containing a denied
-- talent from its pool, since later rank allocation could otherwise learn one.
function M.filter_wanderer_birth(birth,actor)
 for _,class in ipairs(birth.all_classes) do
  local nodes={}
  for _,node in ipairs(class.nodes) do
   if M.allowed_class(node.id) then
    local def=node.def
    local copy={}; for k,v in pairs(def) do copy[k]=v end
    for _,key in ipairs({'talents_types','unlockable_talents_types'}) do
     local trees=def[key]; if type(trees)=='function' then trees=trees(birth) end
     if type(trees)=='table' then
      local safe={}
      for tree,value in pairs(trees) do
       local td=actor:getTalentTypeFrom(tree); local allowed=true
       for _,t in ipairs(td and td.talents or {}) do if not M.allowed_talent(t.id) then allowed=false; break end end
       if allowed then safe[tree]=value end
      end
      copy[key]=safe
     end
    end
    local n={};for k,v in pairs(node) do n[k]=v end;n.def=copy
    -- native Wanderer reads the descriptor registry rather than node.def.
    nodes[#nodes+1]=n
   end
  end
  class.nodes=nodes
 end
 -- Restrict descriptor lookups to the copied node definitions.
 local defs={};for k,v in pairs(birth.birth_descriptor_def) do defs[k]=v end
 local subclasses={};for k,v in pairs(defs.subclass) do subclasses[k]=v end
 for _,class in ipairs(birth.all_classes) do for _,node in ipairs(class.nodes) do subclasses[node.id]=node.def end end
 defs.subclass=subclasses;birth.birth_descriptor_def=defs
end
function M.install()
 if M.installed then return end
 M.installed=true
 headless_plane_cast_allowed=plane_cast_allowed
 local defs=require('engine.interface.ActorTalents').talents_def
 for id,talent in pairs(defs) do if type(id)=='string' and not M.allowed_talent(id) then
  local denied_id=id
  talent.not_on_random_boss=true
  for _,method in ipairs({'action','activate'}) do
   if talent[method] then talent[method]=function() error('content policy rejects talent: '..denied_id) end end
  end
 end end
 for _,name in ipairs({'engine.interface.ActorTalents','mod.class.Actor','mod.class.Player','mod.class.NPC','mod.class.PartyMember'}) do
  local cls=require(name)
  for _,method in ipairs({'learnTalent','useTalent','forceUseTalent'}) do
   local original=cls[method]
   if original then cls[method]=function(self,id,...)
    local key=type(id)=='table' and id.id or id
    M.check_talent(key,self)
    if method~='learnTalent' and not plane_cast_allowed(self,key) then return nil end
    return original(self,id,...)
   end end
  end
 end
 local Game=require 'mod.class.Game'
 Game.chronoClone=function() error('content policy rejects timeline cloning') end
 Game.chronoRestore=function() error('content policy rejects timeline restore') end
 local Object=require 'mod.class.Object'
 local use_object=Object.useObject
 Object.useObject=function(self,who,...)
  if self.use_talent then M.check_talent(self.use_talent.id,who) end
  return use_object(self,who,...)
 end
end
return M
