-- Protocol entrypoint; gameplay methods remain unavailable until an adapter is installed.
local json = require 'json_validate'
dofile('/probe.lua')
local scenario = require 'scene'
if _G.mime and require('native_partition_runtime').ready then native_catalog_anchor_enabled=true end
local visibility = require 'visibility'
local visual_metadata = require 'visual_metadata'
local snapshot = require 'snapshot_experiment'
local native_actions = require 'native_actions'
local create_scene=scenario.create
scenario.create=function(...)
    -- Game class loading needs these headless display shims before policy
    -- installs its class methods. Scene installs the same shims itself.
    core.display.getModesList=function() return {} end
    core.display.FBOActive=function() return false end
    package.loaded['engine.Module']=setmetatable({}, {__index=function(_,k) error('unavailable desktop module operation '..k) end})
    require('content_policy').install()
    return create_scene(...)
end
local navigation = require 'navigation'
local nav={status='idle'}
local rescue_ready=true
local rescue=require 'rescue'
local graph_codec = require 'graph_codec'
local aioo_factory = require 'player_aioo'
local ai_input_task = require 'ai_input_task'
local aioo
local state, generation, pending, terminal = nil, restart_generation or 0, false, nil
local function init_aioo()
    config.settings.player_aioo_stop_on_rare=false
    config.settings.player_aioo_stop_enemy_count=0
    aioo=aioo_factory.load_source(headless_aioo_source(),require('mod.class.Player'),nil,true)
    require('native_zone').install_loading_adapter()
    require('content_policy').bind_plane_control(function(actor)
        return state and actor==state.player and actor==state.game.player and
            require('native_control').is_core(state,actor) and not aioo.is_active() and not ai_input_task.active()
    end)
end
local json_archive_limit = 1000000
local snapshot_format = 'tome-headless-snapshot-v1'
local snapshot_build = 'tome-1.7.6-headless-b5ea-v6-navigation'
local partition_active=false
local bootstrap_migration_import
local function validate_saved_day(day)
 assert(day==nil or type(day)=='number' and day==math.floor(day) and day>=0 and day<365,'invalid native calendar day')
 return day
end
local partition_registry,partition_writer,partition_reader,partition_parts
local warm_identity,warm_pending,warm_pins,warm_committed_hot
local post_frame_pending
local settling_stopped_ai=false
local progress_seen, progress_positions, progress_enemy_lows, progress_enemy_sight = {}, {}, {}, {}
local function capture_progress(initial)
    local progressed=false
    for key in pairs(state.navigation_memory or {}) do
        if not progress_seen[key] then progress_seen[key]=true; if not initial then progressed=true end end
    end
    local pos=tostring(state.player.x)..':'..tostring(state.player.y)
    if not progress_positions[pos] then progress_positions[pos]=true; if not initial then progressed=true end end
    local threats,known={},{}
    for _,roster in ipairs({state.enemies,state.combatants or {}}) do for _,foe in ipairs(roster) do
        if not known[foe] then threats[#threats+1]=foe;known[foe]=true end
    end end
    for _,foe in ipairs(threats) do
        if not foe.dead and state.visible[foe.uid] then
            local id=tostring(foe.uid); local old=progress_enemy_lows[id]
            if old and foe.life<old then progressed=true end
            if not old or foe.life<old then progress_enemy_lows[id]=foe.life end
            progress_enemy_sight[id]={x=foe.x,y=foe.y}
        else
            local id=tostring(foe.uid); local prior=progress_enemy_sight[id]
            if prior and not prior.defeated and state.shared_seen[prior.x+prior.y*state.map.w] and foe.dead and foe.x==prior.x and foe.y==prior.y then
                prior.defeated=true; progressed=true
            end
        end
    end
    return progressed
end
local function begin_progress()
    progress_seen={}; progress_positions={}; progress_enemy_lows={}; progress_enemy_sight={}; capture_progress(true)
end
local health=require('automation_health').new(rescue)
local function reset_health() health.reset() end
local function acknowledge_health() return health.acknowledge() end
local function check_health() return health.check(state) end
local function encode_health_alert()
    local alert=health.publish()
    if not alert then return json.null end
    local result=json.array({})
    for _,e in ipairs(alert) do result[#result+1]=json.object(e) end
    return result
end
local dm_bind_allowed = false
local last_id = restart_id or 0
local down_events, next_down_event, alarm_previous_paused = {}, 1, nil
local function register_down(actor)
    if state and state.game.level and state.game.level.source_level and state.game.level:hasEntity(actor) then
        -- A downed body cannot stay on the temporary map while control moves
        -- back to its squad. Use the same native teardown as an expired cast.
        local level=state.game.level
        local caster=level.plane_owner or actor.dream_plane_trapper or actor
        if state.game.zone.is_demon_plane and caster:isTalentActive('T_DEMON_PLANE') then
            caster:forceUseTalent('T_DEMON_PLANE',{ignore_energy=true})
        elseif state.game.zone.is_dream_scape then
            caster:removeEffect(caster.EFF_DREAMSCAPE)
        end
    end
    actor._mercenary_down_event_id=next_down_event
    down_events[#down_events+1]={id=next_down_event,actor_id=actor.uid,serial=actor._mercenary_down_serial or 1,turn=state and state.game.turn or 0}
    next_down_event=next_down_event+1
    if state and alarm_previous_paused==nil then
        alarm_previous_paused=state.game.paused and true or false
        state.game.paused=true
    end
end
local function encode_down_events()
    local result=json.array()
    for _,event in ipairs(down_events) do result[#result+1]=json.object({id=event.id,actor_id=event.actor_id,serial=event.serial,turn=event.turn}) end
    return result
end
local function valid_down_archive(a)
    if not json.isarray(a.down_events) or type(a.pending_action)~='boolean' or type(a.next_down_event)~='number' or a.next_down_event~=math.floor(a.next_down_event) or a.next_down_event<1 then return false end
    if a.alarm_previous_paused~=json.null and type(a.alarm_previous_paused)~='boolean' then return false end
    if #a.down_events==0 and (a.pending_action or a.alarm_previous_paused~=json.null) then return false end
    if #a.down_events>0 and type(a.alarm_previous_paused)~='boolean' then return false end
    local previous=0
    for _,e in ipairs(a.down_events) do
        if not json.isobject(e) or type(e.id)~='number' or e.id~=math.floor(e.id) or e.id<=previous or e.id>=a.next_down_event or type(e.actor_id)~='number' or e.actor_id~=math.floor(e.actor_id) or e.actor_id<1 or type(e.serial)~='number' or e.serial~=math.floor(e.serial) or e.serial<1 or type(e.turn)~='number' or e.turn~=math.floor(e.turn) or e.turn<0 then return false end
        previous=e.id
    end
    return true
end
local function bind_down_listener(initial)
    rescue.set_down_listener(register_down)
    if initial then for _,actor in ipairs(state.allies) do if rescue.is_down(actor) then register_down(actor) end end end
end
local decision_base_done = false
local state_seed = restart_seed
local state_fixture = restart_fixture or 'standard'
local function send(s) protocol_write(s .. '\n') end
local function reply(id, result)
    send(json.encode(json.object({id=id, ok=true, result=json.object(result)})))
end
local function reject(id, code)
    send(json.encode(json.object({id=id or json.null, ok=false, error=json.object({code=code, outcome='rejected'})})))
end
local function bind_native_control()
    if state_fixture~='formal' then return end
    require('native_control').bind(state,function(previous)
        return aioo.prepare_control_switch(previous)
    end,function(previous,current)
        ai_input_task.note_control(previous,current,state.control_serial)
        if not ai_input_task.active() then aioo.stop_owned(previous,'control_changed') end
        if nav.status=='running' then nav.status='stopped';nav.stop_reason='control_changed' end
        state.map.clean_fov=true
        state.game.target.forced=nil
    end)
end
local function sync_plane()
    local g=state.game
    if not state.map or state.map==g.level.map then return end
    local origin=state._plane_origin
    if origin then
        assert(g.level.map==origin.map,'unexpected temporary level return')
        state.terrain_memory=origin.terrain_memory
        state.navigation_memory=origin.navigation_memory
        state._plane_origin=nil
    else
        assert(g.level.source_level and g.level.source_level.map==state.map and g.level.source_zone and
            require('native_zone').is_temporary(g.zone),'unexpected native level transition')
        local caster=g.level.plane_owner or state.player
        local effect=g.zone.is_demon_plane and caster:isTalentActive('T_DEMON_PLANE') or caster.tmp.EFF_DREAMSCAPE
        local target=assert(effect and effect.target,'missing plane target')
        local opponent=g.party:hasMember(caster) and target or caster
        state._plane_origin={map=state.map,terrain_memory=state.terrain_memory,navigation_memory=state.navigation_memory,
            shared_seen=state.shared_seen,opponent=opponent}
        state.terrain_memory={};state.navigation_memory={}
    end
    state.map=g.level.map;state.visual_emit=state.map.particleEmitter
    nav={status='idle'}
    g.target.forced=nil;state.map.clean_fov=true
    if not state.player.dead then state.player:doFOV() end
end
local function refresh_visibility()
    assert(state.player==state.game.player,'native_control_transition_unverified')
    sync_plane()
    visibility.refresh(state)
    navigation.capture(state,state.player)
    require('rule_events').bind(state)
end
local function public_effects(actor)
    local out=json.array()
    for id,effect in pairs(actor.tmp or {}) do
        local def=actor.tempeffect_def and actor.tempeffect_def[id]
        if type(id)=='string' and type(effect)=='table' and type(effect.dur)=='number' and effect.dur==effect.dur and math.abs(effect.dur)<math.huge then
            local source=effect.src
            local visible_source=json.null
            if source and state then
                for _,ally in ipairs(state.allies) do if source==ally then visible_source=ally.name end end
                for _,foe in ipairs(state.combatants or state.enemies) do if source==foe and state.visible and state.visible[foe.uid] then visible_source=foe.name end end
            end
            out[#out+1]=json.object({id=id,name=def and type(def.desc)=='string' and def.desc or (def and type(def.name)=='string' and def.name or id),dur=effect.dur,status=def and def.status or 'unknown',source=visible_source,icon=def and visual_metadata.icon(def.image) or json.null})
        end
    end
    table.sort(out,function(a,b) return a.id<b.id end)
    return out
end
local public_resources=require('resource_projection').public
local function public_equipment(actor)
    local out=json.array()
    local source_by_uid={}
    if state and state.formal_differences then
        for i,member in ipairs(state.allies) do
            if member==actor and state.formal_differences[i] then
                for _,row in ipairs(state.formal_differences[i].equipment or {}) do
                    if row.uid then source_by_uid[row.uid]=row end
                end
            end
        end
    end
    for _,slot in ipairs(actor.inven_def or {}) do
        if slot.short_name~='INVEN' then
            local inv=actor:getInven(slot.id)
            for _,item in ipairs(inv or {}) do
                local ok,name=pcall(function() return tostring(item:getName{no_count=true}) end)
                local source=source_by_uid[item.uid]
                local combat=item.combat or item.special_combat or {}
                local metrics=json.object({})
                for _,key in ipairs({'dam','apr','physcrit','physspeed','block'}) do
                    local value=combat[key]
                    if type(value)=='number' then metrics[key]=value end
                end
                out[#out+1]=json.object({slot=slot.short_name,uid=item.uid,name=ok and name or item.name or 'unknown',source_name=source and source.source_name or json.null,metrics=metrics})
            end
        end
    end
    return out
end
local function mission_complete()
    if state and (state.campaign_bootstrap or state._dm_area_outside or state._plane_origin or
        (state.game.level and state.game.level.source_level)) then return false end
    if state_fixture=='exploration' or state_fixture=='recovery' or state_fixture=='exploration_complete' then return false end
    for _,foe in ipairs(state.enemies) do if not foe.dead then return false end end
    if state_fixture=='formal' and ((require('encounter_config') and require('encounter_config').zone)
        or state._dm_current_area and state._dm_current_area~='__temporary_scene__') then
        for _,actor in pairs(state.game.level.entities)do
            if not actor.dead and actor.life and actor.reactionToward and actor:reactionToward(state.player)<0 then return false end
        end
    end
    return true
end
local function has_down()
    for _,ally in ipairs(state.allies) do if rescue.is_down(ally) then return true end end
    return false
end
require('rule_events').set_interrupt_check(function()
    return #down_events>0 or (state and mission_complete() and not has_down())
end)
local function observe()
    local p,map,Map=state.player,state.map,state.Map
    local rows, explored, visible, terrain_visuals, party, enemies=json.array(),json.array(),json.array(),json.array(),json.array(),json.array()
    if map then for y=0,map.h-1 do
        local line,terrain_line,visible_line={},{},{}
        local visual_line=json.array()
        for x=0,map.w-1 do
            local glyph=' '
            if state.shared_seen[x+y*map.w] then
                local terrain=map(x,y,Map.TERRAIN)
                glyph=terrain and terrain.display or ' '
                for i,ally in ipairs(state.allies) do if ally.x==x and ally.y==y and not ally.dead and map(x,y,Map.ACTOR)==ally then glyph=(i==1 and '@' or string.char(97+(i-2)%26)) end end
                for _,a in ipairs(state.auxiliaries or {}) do if a.x==x and a.y==y and state.visible[a.uid] then glyph='f' end end
                for _,foe in ipairs(state.combatants or state.enemies) do if foe.x==x and foe.y==y and state.visible[foe.uid] then glyph='e' end end
            end
            local seen=state.shared_seen[x+y*map.w]
            local remembered=state.terrain_memory and state.terrain_memory[x+y*map.w]
            terrain_line[#terrain_line+1]=remembered and remembered.glyph or ' '
            visual_line[#visual_line+1]=remembered and visual_metadata.terrain_json(remembered,seen) or json.null
            visible_line[#visible_line+1]=seen and '1' or '0'
            line[#line+1]=glyph
        end
        rows[#rows+1]=table.concat(line)
        explored[#explored+1]=table.concat(terrain_line)
        visible[#visible+1]=table.concat(visible_line)
        terrain_visuals[#terrain_visuals+1]=visual_line
    end end
    for _,ally in ipairs(state.allies) do local d=ally.descriptor or {}; party[#party+1]=json.object({id=ally.uid,name=ally.name,x=ally.x,y=ally.y,hp=ally.life,max_hp=ally.max_life,level=ally.level or json.null,race=d.subrace or d.race or json.null,class=d.subclass or d.class or json.null,visual=visual_metadata.actor(ally,true),resources=public_resources(ally),equipment=public_equipment(ally),effects=public_effects(ally),dead=ally.dead and true or false,down=rescue.is_down(ally)}) end
    local function actor_projection(a)
        local d=a.descriptor or {}
        return json.object({id=a.uid,name=a.name,x=a.x,y=a.y,hp=a.life,max_hp=a.max_life,level=a.level or json.null,race=d.subrace or d.race or a.subtype or json.null,class=d.subclass or d.class or a.type or json.null,visual=visual_metadata.actor(a,true),resources=public_resources(a),equipment=public_equipment(a),effects=public_effects(a),dead=not not a.dead,down=rescue.is_down(a)})
    end
    if state._plane_origin then
        for i,ally in ipairs(state.allies) do
            if not state.game.level:hasEntity(ally) then party[i].x=nil;party[i].y=nil end
        end
    end
    local controls=json.array()
    for _,a in ipairs(require('native_control').targets(state))do controls[#controls+1]=json.object({id=a.uid,name=a.name})end
    local entities=json.array()
    for _,a in ipairs(state.auxiliaries or {}) do if state.visible[a.uid] or a==p then
        entities[#entities+1]=json.object({id=a.uid,name=a.name,x=a.x,y=a.y,hp=a.life,max_hp=a.max_life,level=a.level or json.null,visual=visual_metadata.actor(a,false),effects=public_effects(a),relation='friendly'})
    end end
    local melee=false
    for _,foe in ipairs(state.combatants or state.enemies) do
        if not foe.dead and state.visible[foe.uid] then
            enemies[#enemies+1]=json.object({id=foe.uid,name=foe.name,x=foe.x,y=foe.y,hp=foe.life,max_hp=foe.max_life,level=foe.level or json.null,rank=foe.rank or json.null,visual=visual_metadata.actor(foe,false),effects=public_effects(foe)})
            if not pending and state.player_visible[foe.uid] and math.max(math.abs(p.x-foe.x),math.abs(p.y-foe.y))==1 then melee=true end
        end
    end
    local talents=json.array()
    for _,talent in ipairs(native_actions.menu(p)) do if talent.id~='T_MERCENARY_RESCUE' then
        if talent.target=='hostile' then talent.target_ids=native_actions.valid_targets(p,talent.id,state.combatants or state.enemies) end
        talents[#talents+1]=json.object(talent)
    end end
    local quiver=p:getInven('QUIVER')
    local ammo=quiver and quiver[1] and quiver[1].combat and quiver[1].combat.shots_left or 0
    local save_reason
    if require('rule_events').has_pending() then save_reason='rule_events_pending'
    elseif settling_stopped_ai then save_reason='ai_stop_settlement'
    elseif health.alert() then save_reason='health_alert'
    elseif rescue.progress(p) then save_reason='rescue_active'
    elseif pending and #down_events==0 then save_reason='pending'
    elseif terminal or not state.game.paused or (#down_events==0 and not p:enoughEnergy()) then save_reason='not_decision'
    elseif (state.game.on_tick_end and next(state.game.on_tick_end.fcts)) or (state.game.on_tick_end_custom and next(state.game.on_tick_end_custom.fcts)) then save_reason='callbacks_pending'
    elseif next(state.game.__coroutines) then save_reason='coroutines_active'
    elseif aioo and aioo.is_active() then save_reason='ai_active'
    elseif nav.status=='running' then save_reason='navigation_active' end
    if not save_reason and state_fixture=='formal' then save_reason='formal_save_unverified' end
    local events=json.array()
    for i=math.max(1,#state.logs-19),#state.logs do events[#events+1]=state.logs[i].str end
    local ai_status,ai_stop_reason,ai_epoch=aioo.control()
    if ai_input_task.active() then ai_status='stopped';ai_stop_reason='native_input_required' end
    local weights=json.object({}); local ai_talents=json.array()
    for tid in pairs(p.talents or {}) do
        if type(tid)=='string' and tid~='T_MERCENARY_RESCUE' and p:knowTalent(tid) then
            local t=p:getTalentFromId(tid)
            if t and t.mode~='passive' then
                weights[tid]=(p.ai_talents and p.ai_talents[tid]) or 1
                ai_talents[#ai_talents+1]=json.object({id=tid,name=t.name or tid,multiplier=weights[tid]})
            end
        end
    end
    table.sort(ai_talents,function(a,b) return a.id<b.id end)
    local ai_config=json.object({talents=ai_talents,stop_on_rare=config.settings.player_aioo_stop_on_rare,stop_enemy_count=config.settings.player_aioo_stop_enemy_count,talent_weights=weights})
    local event_list=encode_down_events()
    local awaiting=#down_events>0
    local down=rescue.is_down(p)
    local leader=state.allies[1]
    local progress=rescue.progress(p)
    local result={inventory=p._dm_world_id and require('campaign_items').list(state) or json.array(),campaign_bootstrap=state.campaign_bootstrap and true or false,campaign_bound=state.allies[1]._dm_world_id~=nil,campaign_withdrawn=state._dm_wipeout and true or false,controlled_actor=actor_projection(p),control_targets=controls,control_change=state.control_change and json.object(state.control_change) or json.null,rule_events=require('rule_events').public(state),entities=entities,input_request=require('native_inputs').public(),resolutions=json.array(state.resolutions or {}),last_action=state.last_action and json.object(state.last_action) or json.null,navigation=json.object({status=nav.status,x=nav.x or json.null,y=nav.y or json.null,stop_reason=nav.stop_reason or json.null}),down_events=event_list,mission_complete=mission_complete(),leader_id=leader.uid,control_actor_id=p.uid,rescue_progress=progress and json.object(progress) or json.null,ai_modes=json.array({'sweep','explore','rest'}),ai_mode=aioo.mode() or json.null,ai_alert=encode_health_alert(),ai_native_turn_count=aioo.native_turn_count(),ai_phase=aioo.phase() or json.null,ai_last_tid=type(p.ai_state.last_tid)=='string' and p.ai_state.last_tid or json.null,fixture=state_fixture,ai_config=ai_config,ai_status=ai_status,ai_stop_reason=ai_stop_reason or json.null,ai_epoch=ai_epoch,generation=generation,map=rows,explored_map=explored,visible_map=visible,terrain_visuals=terrain_visuals,party=party,enemies=enemies,events=events,talents=talents,ammo=ammo,save_unavailable_reason=save_reason or json.null,capabilities=json.object({use_item=p._dm_world_id~=nil and not awaiting and not progress and not down and not pending and not terminal and not p.dead,native_control=not awaiting and not progress and not pending and not terminal and not require('native_inputs').has_pending() and #controls>0,input_response=require('native_inputs').has_pending(),navigate_start=not awaiting and not progress and not down and not pending and not terminal and not p.dead,navigate_step=nav.status=='running' and not awaiting and not progress and not down and not pending and not terminal and not p.dead,confirm_down=awaiting and not terminal,takeover=rescue_ready and not pending and not terminal and (down or (not require('native_control').is_core(state,p) and rescue.is_down(leader))),return_control=rescue_ready and require('native_control').is_core(state,p) and not progress and not pending and (not terminal or terminal=='victory') and p~=leader and not rescue.is_down(leader),rescue_start=rescue_ready and require('native_control').is_core(state,p) and not awaiting and not pending and not terminal and not down and not progress,rescue_step=rescue_ready and not awaiting and not pending and not terminal and not down and progress~=nil,rescue_cancel=rescue_ready and not pending and not terminal and not down and progress~=nil,ranged=not awaiting and not progress and not down and not pending and not terminal and not p.dead and ammo>0 and native_actions.can_shoot(p),talent=not awaiting and not progress and not down and not pending and not terminal and not p.dead,melee=not awaiting and not progress and not down and melee and not terminal and true or false,wait=not awaiting and not progress and not down and not pending and not terminal and not p.dead,move=not awaiting and not progress and not down and not pending and not terminal and not p.dead,ai_step=not awaiting and not down and ai_status=='running' and not pending and not terminal and not p.dead,ai_start=not awaiting and not progress and not mission_complete() and not down and ai_status~='running' and not pending and not terminal and not p.dead,ai_config=not awaiting and not progress and not down and ai_status~='running' and not pending and not terminal and not p.dead,new_game=not awaiting and not pending and state.allies[1]._dm_world_id==nil}),turn=state.game.turn,paused=state.game.paused and true or false,status=terminal or (awaiting and 'awaiting_down_confirmation') or (mission_complete() and has_down() and 'pending_rescue' or 'active')}
    if state._plane_origin then
        result.temporary_plane=state.game.zone.short_name
        result.capabilities.takeover=false
        result.capabilities.return_control=false
        result.capabilities.rescue_start=false
    end
    result.map_available=map~=nil;result.area_outside=not not (state._dm_area_outside and not map)
    if not map then assert(result.area_outside,'missing native map outside camp');for key in pairs(result.capabilities)do result.capabilities[key]=false end end
    return result
end
observe=require('localization').wrap(observe)
-- ToME 1.7.6 defers these four NPC life/psi adjustments to the end of birth.
local solipsism_birth={[48]='T_SOLIPSISM',[81]='T_BALANCE',[120]='T_CLARITY',[162]='T_DISMISSAL'}
local function flush_creation_callbacks(g,captured,owns,actor)
    for _=1,10 do
        if #captured.fcts==0 then return end
        assert(#captured.fcts<=128,'too many native item callbacks')
        local prior={}
        for _,fn in ipairs(captured.fcts)do
            local _,info=require('native_function_env').catalog_prototype(fn)
            local name,owner=debug.getupvalue(fn,1)
            if info.source=='@/mod/class/Object.lua' and info.linedefined==2509 and info.lastlinedefined==2517 and info.nups==1 then
                assert(name=='self' and (owns(owner) or actor and require('local_area').inert_identification(info,owner)),'native item callback owner mismatch')
            elseif actor and info.source=='@/data/talents/psionic/solipsism.lua' and solipsism_birth[info.linedefined] and info.lastlinedefined==info.linedefined+4 and info.nups==1 then
                assert(name=='self' and owner==actor and actor:knowTalent(solipsism_birth[info.linedefined]),'native solipsism callback owner mismatch')
            elseif actor and info.source=='@/mod/dialogs/ShowEquipInven.lua' and info.linedefined==215 and info.lastlinedefined==215 and info.nups==1 then
                assert(name=='self' and owner.inven_actor==actor and not g:hasDialog(owner),'native crafting dialog owner mismatch')
            elseif actor and info.source=='@/mod/class/Actor.lua' and info.linedefined==6341 and info.lastlinedefined==6350 then
                -- Native talent bookkeeping after the alchemy action.
                local actor_name,owner_actor=debug.getupvalue(fn,2)
                assert(name=='ab' and owner.id=='T_CREATE_ALCHEMIST_GEMS' and actor_name=='self' and owner_actor==actor,'native crafting talent owner mismatch')
            elseif actor and info.source=='@/data-orcs/talents/steam/steam.lua' and info.linedefined==201 and info.lastlinedefined==208 and info.nups==1 then
                -- The native crafting callback checks the owning mage's achievement.
                assert(name=='self' and owner==actor,'native crafting callback owner mismatch')
            elseif actor and info.source=='@/data-orcs/talents/steam/engineering.lua' and info.linedefined==69 and info.lastlinedefined==78 and info.nups==1 then
                -- Innovation reapplies the owner's worn equipment after allocation.
                assert(name=='self' and owner==actor and actor:knowTalent(actor.T_INNOVATION),'native innovation callback owner mismatch')
            elseif actor and info.source=='@/data/talents/techniques/duelist.lua' and info.linedefined==32 and info.lastlinedefined==36 and info.nups==2 then
                -- Native Dual Weapon Mastery initializes the NPC's parry after birth.
                local talent_name,talent=debug.getupvalue(fn,2)
                assert(name=='self' and owner==actor and talent_name=='t' and
                       talent==actor:getTalentFromId(actor.T_DUAL_WEAPON_MASTERY),'native duelist callback owner mismatch')
            else
                error('unknown native creation callback '..info.source..':'..info.linedefined..'-'..info.lastlinedefined)
            end
            prior[fn]=true
        end
        g:onTickEndExecute()
        for _,fn in ipairs(captured.fcts)do assert(not prior[fn],'native item callback requested another frame')end
        assert(not next(g.__coroutines) and not require('native_inputs').has_pending() and
               not require('rule_events').has_pending(),'native item callback suspended')
    end
    error('native item callback batch limit')
end

local function capture_manual_frame()
    local g=state.game
    if (g.on_tick_end and next(g.on_tick_end.fcts)) or (g.on_tick_end_custom and next(g.on_tick_end_custom.fcts)) or
        next(g.__coroutines) or require('rule_events').has_pending() or health.alert() or ai_input_task.active() or aioo.is_active() then return nil end
    return {generation=generation,state=state,game=g,level=g.level,zone=g.zone,map=state.map,actor=state.player,turn=g.turn}
end
local function same_manual_frame(owner)
    local g=state.game
    return owner and owner.generation==generation and owner.state==state and owner.game==g and owner.level==g.level and
        owner.zone==g.zone and owner.map==state.map and owner.actor==state.player and owner.turn==g.turn and
        not ai_input_task.active() and not aioo.is_active()
end
local function capture_post_frame()
    local g=state.game;local q=g.on_tick_end
    if not q or not next(q.fcts) then return nil end
    local fcts,names={},{}
    for i,f in ipairs(q.fcts)do fcts[i]=f end
    for k,v in pairs(q.names)do names[k]=v end
    return {generation=generation,game=g,level=g.level,zone=g.zone,queue=q,fcts=fcts,names=names}
end
local function valid_post_frame(token)
    local g=state.game
    if not token or token.generation~=generation or token.game~=g or token.level~=g.level or token.zone~=g.zone or token.queue~=g.on_tick_end then return false end
    local q=token.queue;if #q.fcts~=#token.fcts then return false end
    for i,f in ipairs(token.fcts)do if q.fcts[i]~=f then return false end end
    for k,v in pairs(q.names)do if token.names[k]~=v then return false end end
    for k,v in pairs(token.names)do if q.names[k]~=v then return false end end
    return true
end
local manual_input_frame
local function remember_manual_input(owner)
    if not same_manual_frame(owner) then return end
    owner.input_id=require('native_inputs').public().id
    owner.queued=capture_post_frame()
    manual_input_frame=owner
end
local function begin_manual_input(input_id)
    local owner=manual_input_frame
    manual_input_frame=nil
    if not same_manual_frame(owner) or input_id~=owner.input_id then return nil end
    if owner.queued then
        if not valid_post_frame(owner.queued) then return nil end
    elseif capture_post_frame() then return nil end
    return owner
end
local function publish_manual_post_frame(owner)
    if not same_manual_frame(owner) then return false end
    post_frame_pending=capture_post_frame()
    return post_frame_pending~=nil
end
local function advance_to_boundary(budget)
    local initial_empty=not (state.game.on_tick_end and next(state.game.on_tick_end.fcts)) and not (state.game.on_tick_end_custom and next(state.game.on_tick_end_custom.fcts))
    local authorized=initial_empty or valid_post_frame(post_frame_pending)
    post_frame_pending=nil
    local function settle_native_post_frame()
        local g=state.game;local queue=g.on_tick_end and g.on_tick_end.fcts or {}
        if #queue==0 then return true end
        if not authorized or (g.on_tick_end_custom and next(g.on_tick_end_custom.fcts)) or next(g.__coroutines) or require('native_inputs').has_pending() or require('rule_events').has_pending() or health.alert() then return false end
        local turn,level,zone=g.turn,g.level,g.zone
        -- Native paused GameTurnBased tick executes exactly this post-frame
        -- queue before another scheduler tick. Preserve real callbacks/effects.
        g:onTickEndExecute()
        assert(g.turn==turn,'native post-frame changed turn')
        if g.level~=level or g.zone~=zone then sync_plane() end
        if require('native_inputs').has_pending() or require('rule_events').has_pending() or next(g.__coroutines) or (g.on_tick_end_custom and next(g.on_tick_end_custom.fcts)) then return false end
        if next(g.on_tick_end.fcts) then
            post_frame_pending=capture_post_frame()
            return false
        end
        return true
    end
    local function terminal_audit(result)
        if state_fixture~='formal' then return end
        for i,foe in ipairs(state.enemies) do print('FORMAL_TERMINAL_ENEMY',result,i,foe.uid,foe.dead and 'dead' or 'alive') end
        for i,ally in ipairs(state.allies) do print('FORMAL_TERMINAL_PARTY',result,i,ally.uid,rescue.is_down(ally) and 'down' or 'standing') end
    end
    local function boundary()
        sync_plane()
        if require('native_inputs').has_pending() then refresh_visibility();return 'await_input' end
        require('rule_events').flush()
        if #down_events>0 and state._plane_origin then
            -- The return callback can queue its native actor cleanup. Drain
            -- that owned queue before exposing a down confirmation.
            local settled=false
            for _=1,8 do
                settled=settle_native_post_frame()
                if settled or not valid_post_frame(post_frame_pending) then break end
                post_frame_pending=nil
            end
            if not settled then pending=true;return 'pending' end
        end
        local alive_party=false
        for _,ally in ipairs(state.allies) do if not ally.dead and not rescue.is_down(ally) then alive_party=true; break end end
        if not alive_party then pending=false; terminal='defeat'; aioo.stop('defeat'); terminal_audit(terminal); return 'terminal' end
        if #down_events>0 then
            if aioo.is_active() then aioo.stop('party_down') end
            refresh_visibility(); return 'input'
        end
        if rescue.is_down(state.player) then pending=false; state.game.paused=true; aioo.stop('control_down'); refresh_visibility(); return 'decision' end
        local alive=false
        for _,foe in ipairs(state.enemies) do if not foe.dead then alive=true; break end end
        if not alive and mission_complete() and not has_down() then pending=false; terminal='victory'; aioo.stop('victory'); terminal_audit(terminal); return 'terminal' end
        if mission_complete() and has_down() and aioo.is_active() then aioo.stop('mission_complete') end
        if state.game.paused and state.player:enoughEnergy() then
            if not settle_native_post_frame() then
                if require('native_inputs').has_pending() then refresh_visibility();return 'await_input' end
                pending=true;return 'pending'
            end
            if #down_events>0 then refresh_visibility();return 'input' end
            if not state.game.paused or not state.player:enoughEnergy() then pending=true;return 'pending' end
            state.map.clean_fov=true; state.player:doFOV(); refresh_visibility(); pending=false; decision_base_done=state.control_base_done~=false
            aioo.settle_interrupt()
            if aioo.is_active() and aioo.mode()=='sweep' and capture_progress(false) then aioo.progress_reset() end
            if aioo.is_active() or settling_stopped_ai then
                if check_health() then aioo.stop('health_alert') end
            else health.manual(state) end
            settling_stopped_ai=false
            return 'decision'
        end
    end
    for _=1,budget do
        local result=boundary(); if result then return result end
        if aioo.is_active() or settling_stopped_ai then aioo.guard_tick(function() state.game:tick() end)
        elseif rescue.progress(state.player) then
            -- The native Player scheduler otherwise advances rest on every tick.
            -- Only an explicit rescue_step may authorize the next action.
            local p=state.player; local old=rawget(p,'restStep')
            p.restStep=function() return false end
            local ok,err=xpcall(function() state.game:tick() end,debug.traceback)
            p.restStep=old
            if not ok then error(err) end
        else state.game:tick() end
    end
    local result=boundary(); if result then return result end
    pending=true; return 'pending'
end
if restart_id then
    local ok, result=xpcall(function() return scenario.create(restart_seed,state_fixture) end,debug.traceback)
    if not ok then
        print(tostring(result))
        send('{"id":'..string.format('%.0f',restart_id)..',"ok":false,"error":{"code":"reset_failed","outcome":"unknown"}}')
        return
    end
    state=result; if state_fixture=='formal' then require('dm_charisma').install(state,state_seed) end; init_aioo(); reset_health(); bind_native_control(); bind_down_listener(true); refresh_visibility()
    reply(restart_id,{accepted=true,generation=generation,boundary=#down_events>0 and 'input' or 'decision'})
end
while true do
    local line, too_long = protocol_read()
    if line == nil then break end
    local req = not too_long and json.decode(line) or nil
    local id = json.isobject(req) and req.id or nil
    local valid_id = type(id)=='number' and id==math.floor(id) and id>0 and id<=9007199254740991
    local sid = valid_id and string.format('%.0f', id) or 'null'
    local valid = json.isobject(req) and valid_id and req.protocol=='tome-headless-v1' and type(req.method)=='string' and json.isobject(req.params)
    if valid and req.expected_generation~=nil then
        valid = type(req.expected_generation)=='number' and req.expected_generation>=0 and req.expected_generation==math.floor(req.expected_generation) and req.expected_generation<=9007199254740991
    end
    if valid and req.method~='capabilities' and req.method~='observe' and req.method~='dm_inspect' and req.method~='partition_enable' then bootstrap_migration_import=nil end
    if not valid then
        send('{"id":'..sid..',"ok":false,"error":{"code":"invalid_request","outcome":"rejected"}}')
    elseif id<=last_id then reject(id,'duplicate_or_old_id')
    elseif warm_pending and req.method~='partition_confirm' and req.method~='partition_abort' then last_id=id;reject(id,'partition_commit_pending')
    elseif req.method=='capabilities' then
        last_id=id
        send('{"id":'..sid..',"ok":true,"result":{"protocol":"tome-headless-v1","ai_provider":"player_aioo_custom","ai_modes":["sweep","explore","rest"],"methods":{"capabilities":true,"create":true,"reset":true,"observe":true,"act":true,"advance":true,"save":true,"restore":true,"ai_stop":true},"web_commands":{"native_control":true,"melee":true,"wait":true,"move":true,"navigate_start":true,"navigate_step":true,"new_game":true,"ai_start":true,"ai_step":true,"ai_config":true,"ranged":true,"talent":true,"use_item":true,"takeover":true,"return_control":true,"rescue_start":true,"rescue_step":true,"rescue_cancel":true,"confirm_down":true,"input_response":true}}}')
    elseif req.method=='create' then
        last_id=id
        local seed=req.params.seed
        local fixture=req.params.fixture or 'standard'
        if state then reject(id,'already_created')
        elseif fixture~='formal' and fixture~='rescue' and fixture~='standard' and fixture~='skill_types' and fixture~='ranged_policy' and fixture~='exploration' and fixture~='recovery' and fixture~='exploration_complete' then reject(id,'invalid_fixture')
        elseif type(seed)~='number' or seed<0 or seed>2147483647 or seed~=math.floor(seed) then reject(id,'invalid_seed')
        else
            local ok, result = xpcall(function() return scenario.create(seed,fixture) end, debug.traceback)
            if not ok then print(tostring(result)); send('{"id":'..sid..',"ok":false,"error":{"code":"create_failed","outcome":"unknown"}}'); break end
            state=result; state_seed=seed; state_fixture=fixture; generation=1; dm_bind_allowed=fixture=='formal'; if fixture=='formal' then require('dm_charisma').install(state,seed) end; init_aioo(); reset_health(); bind_native_control(); bind_down_listener(true); refresh_visibility()
            reply(id,{accepted=true,generation=generation,boundary=#down_events>0 and 'input' or 'decision'})
        end
    elseif req.method=='partition_enable' then
        last_id=id
        local imported=bootstrap_migration_import;bootstrap_migration_import=nil
        if not require('native_partition_runtime').ready then reject(id,'partition_unavailable')
        elseif not state then reject(id,'not_created')
        elseif req.expected_generation~=generation then reject(id,'stale_generation')
        elseif partition_active then reject(id,'already_enabled')
        elseif state_fixture~='formal' or (not state._dm_local_areas and not req.params.bootstrap_migration) then reject(id,'partition_scene_required')
        else
            local ok,err=xpcall(function()
                for k in pairs(req.params)do assert(k=='bootstrap_migration','invalid partition enable field')end
                if req.params.bootstrap_migration then
                    local p=req.params.bootstrap_migration
                    assert(type(p)=='table' and imported==generation,'bootstrap import qualification missing')
                    for k in pairs(p)do assert(k=='world_id' or k=='campaign_id' or k=='world_clock','invalid bootstrap field')end
                    assert(type(p.world_id)=='string' and p.world_id==state._dm_items_world and type(p.campaign_id)=='string' and p.campaign_id==state._dm_items_campaign,'bootstrap scope mismatch')
                    local c=p.world_clock;assert(type(c)=='table','bootstrap clock required')
                    for k in pairs(c)do assert(k=='world_tick' or k=='day_in_quarter','invalid clock field')end
                    assert(type(c.world_tick)=='number' and c.world_tick>=0 and c.world_tick==math.floor(c.world_tick) and c.world_tick<=10000000000000 and type(c.day_in_quarter)=='number' and c.day_in_quarter>=0 and c.day_in_quarter<90 and c.day_in_quarter*2==math.floor(c.day_in_quarter*2),'invalid bootstrap clock')
                    local conf=require('encounter_config');local g=state.game
                    assert(conf and conf.purpose=='party_bootstrap' and state.campaign_bootstrap and not state._dm_local_areas and not state._dm_current_area and not state._dm_current_floor and not state._dm_last_area_clock and not state._dm_area_outside,'invalid bootstrap scene')
                    assert(g and g.level and g.zone and state.map==g.level.map and state.player==g.player and g.party and g.party:hasMember(state.player),'invalid bootstrap aliases')
                    assert(#state.allies>0 and #(state.enemies or {})==0,'invalid bootstrap population')
                    for _,a in ipairs(state.allies)do assert(a._dm_world_id and g.party:hasMember(a) and not rescue.is_down(a),'invalid bootstrap party')end
                    assert(not terminal and not pending and not settling_stopped_ai and not aioo.is_active() and nav.status~='running' and #down_events==0 and not health.alert() and not rescue.progress(state.player) and not ai_input_task.active() and not require('native_inputs').has_pending() and not require('rule_events').has_pending(),'unsafe bootstrap boundary')
                    assert(not next(g.__coroutines) and not (g.on_tick_end and next(g.on_tick_end.fcts)) and not (g.on_tick_end_custom and next(g.on_tick_end_custom.fcts)) and not (g.to_re_add_actors and next(g.to_re_add_actors)),'pending bootstrap callbacks')
                    require('local_area').bind(state,{area_id='__temporary_scene__',floor_count=1})
                    require('local_area').park(state,{world_clock=c})
                end
                if state._dm_area_outside and state.game.level then
                    local days=assert(state._dm_last_area_clock,'missing native departure clock')
                    require('local_area').park(state,{world_clock={world_tick=math.floor(days/90),day_in_quarter=days%90}})
                end
                partition_active=true;partition_registry=require('native_partition_store').new()
                partition_writer=require('native_function_env').new_writer()
            end,debug.traceback)
            if not ok then print(tostring(err));send('{"id":'..sid..',"ok":false,"error":{"code":"partition_enable_failed","outcome":"unknown"}}');break end
            reply(id,{accepted=true,generation=generation})
        end
    elseif req.method=='partition_export' or req.method=='partition_prepare' then
        last_id=id
        local warming=req.method=='partition_prepare'
        if not require('native_partition_runtime').ready or not partition_active then reject(id,'partition_unavailable')
        elseif not state then reject(id,'not_created')
        elseif req.expected_generation~=generation then reject(id,'stale_generation')
        elseif warming and not require('native_partition_runtime').warm_ready then reject(id,'warm_unavailable')
        elseif warming and (not warm_identity or not partition_reader or not partition_parts or state.map or not state._dm_area_outside) then reject(id,'warm_unavailable')
        elseif pending or settling_stopped_ai or aioo.is_active() or nav.status=='running' or health.alert() or rescue.progress(state.player) or ai_input_task.active() or require('native_inputs').has_pending() or require('rule_events').has_pending() then reject(id,'unsafe_pending_state')
        elseif not state.game.paused and not (state._dm_area_outside or state.campaign_bootstrap) then reject(id,'not_save_boundary')
        elseif (state.game.on_tick_end and next(state.game.on_tick_end.fcts)) or (state.game.on_tick_end_custom and next(state.game.on_tick_end_custom.fcts)) or next(state.game.__coroutines) then
            for _,queue in ipairs({state.game.on_tick_end and state.game.on_tick_end.fcts or {},state.game.on_tick_end_custom and state.game.on_tick_end_custom.fcts or {}})do for _,fn in pairs(queue)do
                local info=debug.getinfo(fn,'Su');print('PARTITION_PENDING_CALLBACK',info.source,info.linedefined,info.lastlinedefined,info.nups)
            end end
            reject(id,'pending_callbacks')
        else
            local ok,result=xpcall(function()
                if warming then
                    local p=req.params;local scope=p.scope
                    assert(p.index_mode==nil or p.index_mode=='hot-delta-v1','unknown warm index mode')
                    assert(type(p.pending_token)=='string' and #p.pending_token==64 and p.pending_token:match('^[0-9a-f]+$'),'invalid warm token')
                    assert(type(scope)=='table' and scope.build==warm_identity.build and scope.world_id==warm_identity.world_id and scope.campaign_id==warm_identity.campaign_id and scope.battle_id==warm_identity.battle_id,'warm scope mismatch')
                    assert(p.parent_version==warm_identity.version and p.parent_manifest_sha256==warm_identity.manifest_sha256 and type(p.operation_id)=='string' and #p.operation_id>0 and #p.operation_id<=256,'warm parent mismatch')
                    for _,e in pairs(partition_registry:live_entries())do assert(e.owner=='hot' or e.kind=='function','warm operation requires cold owner') end
                end
                local runtime={generation=generation,seed=state_seed,fixture=state_fixture,terminal=terminal,pending=pending,native_boundary=(state._dm_area_outside or state.campaign_bootstrap) and 'campaign_admin' or 'decision',decision_base_done=decision_base_done,down_events=down_events,next_down_event=next_down_event,alarm_previous_paused=alarm_previous_paused,dm_bind_allowed=dm_bind_allowed,nav=nav,health=health.export_state(),provider=aioo.export_state(),rule_events=require('rule_events').export_state(),native_inputs=require('native_inputs').export_state(),progress_seen=progress_seen,progress_positions=progress_positions,progress_enemy_lows=progress_enemy_lows,progress_enemy_sight=progress_enemy_sight,stop_on_rare=config.settings.player_aioo_stop_on_rare,stop_enemy_count=config.settings.player_aioo_stop_enemy_count,rng=rng.state_get(),day_of_year=validate_saved_day(state.game.day_of_year)}
                if partition_reader then require('native_save_partition_scene').materialize_live_owners(state,partition_reader,require('engine.Entity').native_uid_state()) end
                local wire,r,plan,provider=require('native_partition_runtime').export(state,runtime,partition_registry,partition_writer,req.params.protected_by_owner,partition_reader,warming and req.params.index_mode=='hot-delta-v1',warm_committed_hot,warming)
                partition_registry=r
                -- This is an isolated candidate VM. The host must commit all
                -- blobs atomically or discard this VM; it must never reuse it
                -- after a failed transaction.
                require('native_save_partition_scene').evict_inactive(state,plan)
                local after=rng.state_get();local before=runtime.rng
                assert(after.format==before.format and after.index==before.index and after.stored==before.stored and after.normal_spare==before.normal_spare,'native partition save changed RNG')
                for i=1,624 do assert(after.words[i]==before.words[i],'native partition save changed RNG words') end
                wire.format='tome-partitioned-native-v1';wire.generation=generation;wire.boundary='decision';wire.native_boundary=runtime.native_boundary
                wire.world_id=state._dm_items_world;wire.campaign_id=state._dm_items_campaign
                if warming then
                    assert(#wire.dirty_blobs==1 and wire.dirty_blobs[1].partition_id=='hot','warm operation changed cold owner')
                    assert(provider,'missing private hot provider')
                    warm_pending={token=req.params.pending_token,operation_id=req.params.operation_id,identity=warm_identity,wire=wire,provider=provider}
                    wire.pending_token=req.params.pending_token
                end
                return wire
            end,debug.traceback)
            if not ok then print(tostring(result));send('{"id":'..sid..',"ok":false,"error":{"code":"partition_export_failed","outcome":"unknown"}}');break end
            reply(id,result)
        end
    elseif req.method=='partition_confirm' then
        last_id=id
        local p=req.params;local w=warm_pending;local scope=p.scope
        local function sha(v)return type(v)=='string' and #v==64 and v:match('^[0-9a-f]+$') end
        if not w then reject(id,'no_partition_commit_pending')
        else
            local ok,err=xpcall(function()
                local iden=w.identity
                assert(p.pending_token==w.token and type(scope)=='table' and scope.build==iden.build and scope.world_id==iden.world_id and scope.campaign_id==iden.campaign_id and scope.battle_id==iden.battle_id,'warm confirmation identity mismatch')
                assert(p.parent_version==iden.version and p.parent_manifest_sha256==iden.manifest_sha256 and p.new_version==iden.version+1 and sha(p.new_manifest_sha256) and sha(p.hot_sha256),'warm confirmation version mismatch')
                assert(require('engine.Entity').native_uid_state()==w.wire.next_uid and partition_registry:cursor()==w.wire.next_ref,'warm allocator changed while pending')
                local records=w.wire.objects_delta and w.wire.objects_delta.records or w.wire.objects
                for ref,obj in pairs(warm_pins or {})do local e=records[ref];assert(e and e.owner=='hot' and partition_registry:live(ref)==obj,'protected native reference lost') end
                require('native_partition_runtime').rebase_reader(partition_reader,partition_parts,w.wire,partition_writer,warm_committed_hot,w.provider)
                warm_committed_hot=partition_registry:index_owner('hot')
                warm_identity={build=iden.build,world_id=iden.world_id,campaign_id=iden.campaign_id,battle_id=iden.battle_id,version=p.new_version,manifest_sha256=p.new_manifest_sha256}
                warm_pending=nil
            end,debug.traceback)
            if not ok then print(tostring(err));send('{"id":'..sid..',"ok":false,"error":{"code":"partition_confirm_failed","outcome":"unknown"}}');break end
            reply(id,{confirmed=true,version=warm_identity.version,manifest_sha256=warm_identity.manifest_sha256})
        end
    elseif req.method=='partition_abort' then
        last_id=id
        if not warm_pending or req.params.pending_token~=warm_pending.token then send('{"id":'..sid..',"ok":false,"error":{"code":"partition_abort_failed","outcome":"unknown"}}');break end
        reply(id,{aborted=true});break
    elseif req.method=='partition_import' then
        last_id=id
        if not require('native_partition_runtime').ready then reject(id,'partition_unavailable')
        elseif state then reject(id,'already_created')
        elseif req.expected_generation~=nil then reject(id,'invalid_request')
        elseif not json.isobject(req.params.manifest) or req.params.manifest.format~='tome-partitioned-native-v1' or not json.isarray(req.params.blobs) then reject(id,'incompatible_snapshot')
        else
            local ok,result=xpcall(function()
                local manifest=req.params.manifest
                assert(json.isobject(manifest.hot_root) and type(manifest.hot_root.root_ref)=='string' and type(manifest.next_uid)=='number','invalid native partition manifest')
                core.display.getModesList=function()return {}end;core.display.FBOActive=function()return false end
                package.loaded['engine.Module']=setmetatable({}, {__index=function(_,k)error('unavailable desktop module operation '..k)end})
                require('content_policy').install()
                local env=scenario.prepare(0,'formal',true);local shell=game
                require('dm_progression').install();require('native_zone').install_runtime()
                local R=require 'native_partition_runtime'
                local reader,parts=R.reader(manifest,req.params.blobs)
                local root=reader:load(manifest.hot_root.root_ref,{native=true,next_uid=manifest.next_uid,on_root=function(v)R.bind_root(v,shell)end,on_game_loaded=R.loaded_game})
                local app=assert(root.application);local restored=assert(app.state);local runtime=assert(app.runtime)
                assert(runtime.fixture=='formal' and type(runtime.seed)=='number' and type(runtime.generation)=='number','invalid native runtime')
                assert(restored.game==game and restored.player==game.player,'invalid native scene aliases')
                assert((restored.map and game.level and restored.map==game.level.map) or (restored._dm_area_outside and not restored.map and not game.level),'invalid active native floor')
                assert(restored._dm_items_world==manifest.world_id and restored._dm_items_campaign==manifest.campaign_id,'native campaign scope mismatch')
                restored.Map=env.Map
                if restored.map then
                    local areas=assert(restored._dm_local_areas,'missing native area catalog')
                    local area=assert(areas[restored._dm_current_area],'missing active native area')
                    local slot=assert(area.floors[restored._dm_current_floor],'missing active native floor')
                    if not slot.level or not area.zone then
                        local _,loaded=require('native_save_partition_scene').materialize(restored,reader,restored._dm_current_area,restored._dm_current_floor,{next_uid=manifest.next_uid})
                        slot=loaded
                    end
                    if restored._plane_origin then
                        assert(slot.level==game.level.source_level and area.zone==game.level.source_zone and
                            slot.level.map==restored._plane_origin.map,'temporary native partition identity mismatch')
                        require('headless_visuals').install_map(slot.level.map)
                    else
                        assert(slot.level==game.level and slot.level.map==restored.map and area.zone==game.zone,'active native partition identity mismatch')
                    end
                end
                for _,fn in ipairs({game.log,game.logNewest,game.logRollback})do
                    local found=false;for i=1,debug.getinfo(fn,'u').nups do local name=debug.getupvalue(fn,i);if name=='logs' then debug.setupvalue(fn,i,restored.logs);found=true end end
                    assert(found,'native log binding missing')
                end
                if restored.map then require('native_actions').install_visual_adapter(restored.map);restored.visual_emit=restored.map.particleEmitter end
                require('rescue').bind_restore(restored);require('native_inputs').bind(restored);require('campaign_items').install(restored)
                state=restored;state_seed=runtime.seed;state_fixture=runtime.fixture;generation=runtime.generation
                terminal=runtime.terminal;pending=runtime.pending;decision_base_done=runtime.decision_base_done
                down_events=runtime.down_events;next_down_event=runtime.next_down_event;alarm_previous_paused=runtime.alarm_previous_paused;dm_bind_allowed=runtime.dm_bind_allowed;nav=runtime.nav
                progress_seen=runtime.progress_seen;progress_positions=runtime.progress_positions;progress_enemy_lows=runtime.progress_enemy_lows;progress_enemy_sight=runtime.progress_enemy_sight
                init_aioo();aioo.import_state(runtime.provider);health.import_state(runtime.health);require('rule_events').import_state(runtime.rule_events);require('native_inputs').import_state(runtime.native_inputs)
                config.settings.player_aioo_stop_on_rare=runtime.stop_on_rare;config.settings.player_aioo_stop_enemy_count=runtime.stop_enemy_count
                state.game.day_of_year=validate_saved_day(runtime.day_of_year)
                bind_native_control();bind_down_listener(false);if state.map then refresh_visibility()end;rng.state_set(runtime.rng)
                assert(runtime.native_boundary=='decision' or runtime.native_boundary=='campaign_admin','invalid native boundary')
                partition_active=true;partition_reader=reader;partition_parts=parts;partition_registry=reader:registry();partition_writer=reader:function_writer()
                local wi=req.params.warm_identity
                if wi then
                    assert(R.warm_ready,'warm import unavailable')
                    assert(type(wi)=='table' and type(wi.battle_id)=='string' and #wi.battle_id>0 and wi.build==manifest.build and wi.world_id==manifest.world_id and wi.campaign_id==manifest.campaign_id and type(wi.version)=='number' and wi.version>=0 and wi.version==math.floor(wi.version) and type(wi.manifest_sha256)=='string' and #wi.manifest_sha256==64 and wi.manifest_sha256:match('^[0-9a-f]+$'),'invalid warm import identity')
                    warm_identity={build=wi.build,world_id=wi.world_id,campaign_id=wi.campaign_id,battle_id=wi.battle_id,version=wi.version,manifest_sha256=wi.manifest_sha256}
                    -- A cold partition can be the sole strong owner of a hot
                    -- object. Keep those exact committed objects alive before
                    -- any warm operation can mutate and drop its last hot edge.
                    warm_committed_hot=partition_registry:index_owner('hot')
                    warm_pins={}
                    assert(type(manifest.partitions)=='table','missing committed partition catalog')
                    for _,part in ipairs(manifest.partitions)do
                        assert(type(part.strong_refs)=='table','invalid committed strong references')
                        for _,ref in ipairs(part.strong_refs)do
                            local entry=assert(partition_registry:entry(ref),'missing protected native reference')
                            if entry.owner=='hot' and not warm_pins[ref] then warm_pins[ref]=reader:resolve(ref,{native=true,next_uid=manifest.next_uid}) end
                        end
                    end
                end
                return runtime.native_boundary
            end,debug.traceback)
            if not ok then print(tostring(result));send('{"id":'..sid..',"ok":false,"error":{"code":"partition_import_failed","outcome":"unknown"}}');break end
            reply(id,{format='tome-partitioned-native-v1',generation=generation,boundary=terminal and state.map and 'terminal' or 'decision',native_boundary=result})
        end
    elseif req.method=='snapshot_export' then
        last_id=id
        local campaign_admin=state and (not state.game.paused or state.campaign_bootstrap) and not terminal and #down_events==0
            and (state.campaign_bootstrap or state._dm_area_outside)
            and #state.allies>0
        if campaign_admin then for _,a in ipairs(state.allies)do if not a._dm_world_id then campaign_admin=false end end end
        if not require('native_save').ready then reject(id,'snapshot_unavailable')
        elseif not state then reject(id,'not_created')
        elseif req.expected_generation~=generation then reject(id,'stale_generation')
        elseif state_fixture~='formal' then reject(id,'formal_required')
        elseif pending or settling_stopped_ai or (not state.game.paused and not campaign_admin) or aioo.is_active() or nav.status=='running' then reject(id,'not_save_boundary')
        elseif health.alert() or rescue.progress(state.player) or ai_input_task.active() or require('native_inputs').has_pending() or require('rule_events').has_pending() then reject(id,'unsafe_pending_state')
        elseif (state.game.on_tick_end and next(state.game.on_tick_end.fcts)) or (state.game.on_tick_end_custom and next(state.game.on_tick_end_custom.fcts)) or next(state.game.__coroutines) then reject(id,'pending_callbacks')
        else
            local ok,result=xpcall(function()
                local app={}
                for k,v in pairs(state)do if k~='Map' and k~='visual_emit' then app[k]=v end end
                local runtime={generation=generation,seed=state_seed,fixture=state_fixture,terminal=terminal,pending=pending,native_boundary=campaign_admin and 'campaign_admin' or 'decision',
                    decision_base_done=decision_base_done,down_events=down_events,next_down_event=next_down_event,
                    alarm_previous_paused=alarm_previous_paused,dm_bind_allowed=dm_bind_allowed,nav=nav,
                    health=health.export_state(),provider=aioo.export_state(),rule_events=require('rule_events').export_state(),native_inputs=require('native_inputs').export_state(),progress_seen=progress_seen,
                    progress_positions=progress_positions,progress_enemy_lows=progress_enemy_lows,progress_enemy_sight=progress_enemy_sight,
                    stop_on_rare=config.settings.player_aioo_stop_on_rare,stop_enemy_count=config.settings.player_aioo_stop_enemy_count,
                    rng=rng.state_get()}
                local root=require('native_save_root').new(state.game,world,{state=app,runtime=runtime})
                local chunks=require('native_save').export(root)
                local after_rng=rng.state_get();local before_rng=runtime.rng
                assert(after_rng.format==before_rng.format and after_rng.index==before_rng.index and after_rng.stored==before_rng.stored and after_rng.normal_spare==before_rng.normal_spare,'native save changed RNG')
                for i=1,624 do assert(after_rng.words[i]==before_rng.words[i],'native save changed RNG words') end
                local blob=json.encode(json.object({chunks=chunks,next_uid=require('engine.Entity').native_uid_state()}))
                assert(#blob<=67108864,'native snapshot blob exceeds 64 MiB')
                return blob
            end,debug.traceback)
            if not ok then print(tostring(result));send('{"id":'..sid..',"ok":false,"error":{"code":"snapshot_export_failed","outcome":"unknown"}}');break end
            reply(id,{format='tome-native-save-v1',blob=result,generation=generation,boundary='decision',native_boundary=campaign_admin and 'campaign_admin' or 'decision'})
        end
    elseif req.method=='snapshot_import' then
        last_id=id
        if not require('native_save').ready then reject(id,'snapshot_unavailable')
        elseif state then reject(id,'already_created')
        elseif req.expected_generation~=nil then reject(id,'invalid_request')
        elseif req.params.format~='tome-native-save-v1' or type(req.params.blob)~='string' or #req.params.blob>67108864 then reject(id,'incompatible_snapshot')
        else
            local ok,result=xpcall(function()
                local envelope=assert(json.decode(req.params.blob),'invalid native snapshot blob')
                assert(json.isobject(envelope) and json.isobject(envelope.chunks) and type(envelope.next_uid)=='number','invalid native snapshot envelope')
                core.display.getModesList=function() return {} end
                core.display.FBOActive=function() return false end
                package.loaded['engine.Module']=setmetatable({}, {__index=function(_,k) error('unavailable desktop module operation '..k) end})
                require('content_policy').install()
                local env=scenario.prepare(0,'formal',true);local shell=game
                require('dm_progression').install()
                require('native_zone').install_runtime()
                local root=require('native_save').read(envelope.chunks,envelope.next_uid,shell,require('encounter_config'))
                local app=assert(root.application);local restored=assert(app.state);local runtime=assert(app.runtime)
                assert(runtime.fixture=='formal' and type(runtime.seed)=='number' and type(runtime.generation)=='number','invalid native runtime')
                assert(restored.game==game and restored.player==game.player and restored.map==game.level.map,'invalid native scene aliases')
                restored.Map=env.Map
                for _,fn in ipairs({game.log,game.logNewest,game.logRollback})do
                    local found=false
                    for i=1,debug.getinfo(fn,'u').nups do
                        local name=debug.getupvalue(fn,i)
                        if name=='logs' then debug.setupvalue(fn,i,restored.logs);found=true end
                    end
                    assert(found,'native log binding missing')
                end
                require('native_actions').install_visual_adapter(restored.map);restored.visual_emit=restored.map.particleEmitter
                for _,area in pairs(restored._dm_local_areas or {})do for _,slot in pairs(area.floors or {})do
                    if slot.level and slot.level.map~=restored.map then require('headless_visuals').install_map(slot.level.map) end
                end end
                require('rescue').bind_restore(restored);require('native_inputs').bind(restored)
                require('campaign_items').install(restored)
                state=restored;state_seed=runtime.seed;state_fixture=runtime.fixture;generation=runtime.generation
                terminal=runtime.terminal;pending=runtime.pending;decision_base_done=runtime.decision_base_done
                down_events=runtime.down_events;next_down_event=runtime.next_down_event;alarm_previous_paused=runtime.alarm_previous_paused
                dm_bind_allowed=runtime.dm_bind_allowed;nav=runtime.nav
                progress_seen=runtime.progress_seen;progress_positions=runtime.progress_positions;progress_enemy_lows=runtime.progress_enemy_lows;progress_enemy_sight=runtime.progress_enemy_sight
                init_aioo();aioo.import_state(runtime.provider);health.import_state(runtime.health);require('rule_events').import_state(runtime.rule_events);require('native_inputs').import_state(runtime.native_inputs)
                config.settings.player_aioo_stop_on_rare=runtime.stop_on_rare;config.settings.player_aioo_stop_enemy_count=runtime.stop_enemy_count
                bind_native_control();bind_down_listener(false);refresh_visibility();rng.state_set(runtime.rng)
                assert(runtime.native_boundary=='decision' or runtime.native_boundary=='campaign_admin','invalid native boundary')
                return runtime.native_boundary
            end,debug.traceback)
            if not ok then print(tostring(result));send('{"id":'..sid..',"ok":false,"error":{"code":"snapshot_import_failed","outcome":"unknown"}}');break end
            if result=='campaign_admin' then bootstrap_migration_import=generation end
            reply(id,{format='tome-native-save-v1',generation=generation,boundary='decision',native_boundary=result})
        end
    elseif req.method=='save' then
        last_id=id
        if not state then reject(id,'not_created')
        elseif req.expected_generation~=generation then reject(id,'stale_generation')
        elseif terminal or not state.game.paused or (#down_events==0 and (pending or not state.player:enoughEnergy())) then reject(id,'not_save_boundary')
        elseif aioo.is_active() then reject(id,'ai_active')
        elseif health.alert() then reject(id,'health_alert')
        elseif rescue.progress(state.player) then reject(id,'rescue_active')
        elseif ai_input_task.active() then reject(id,'ai_input_pending')
        elseif require('rule_events').has_pending() then reject(id,'rule_events_pending')
        else
            local ok,archive=xpcall(function()
                return json.object({format=snapshot_format,build=snapshot_build,generation=generation,seed=state_seed,fixture=state_fixture,decision_base_done=decision_base_done,pending_action=pending,down_events=encode_down_events(),next_down_event=next_down_event,alarm_previous_paused=alarm_previous_paused==nil and json.null or alarm_previous_paused,ai_settings=json.object({stop_on_rare=config.settings.player_aioo_stop_on_rare,stop_enemy_count=config.settings.player_aioo_stop_enemy_count}),provider_state=graph_codec.encode(aioo.export_state(),{},1000),snapshot=snapshot.capture(state)})
            end,debug.traceback)
            if not ok then print(tostring(archive)); reject(id,'save_unsupported_state')
            elseif #json.encode(archive)>json_archive_limit then reject(id,'save_too_large')
            else reply(id,{archive=archive}) end
        end
    elseif req.method=='restore' then
        last_id=id
        local a,minimum=req.params.archive,req.params.min_generation
        if state then reject(id,'already_created')
        elseif req.expected_generation~=nil then reject(id,'invalid_request')
        elseif type(minimum)~='number' or minimum~=math.floor(minimum) or minimum<1 or minimum>9007199254740991 then reject(id,'invalid_generation')
        elseif not json.isobject(a) or a.format~=snapshot_format or a.build~=snapshot_build or not json.isobject(a.snapshot) or not json.isobject(a.provider_state) or (a.fixture~='formal' and a.fixture~='rescue' and a.fixture~='standard' and a.fixture~='skill_types' and a.fixture~='ranged_policy' and a.fixture~='exploration' and a.fixture~='recovery' and a.fixture~='exploration_complete') or type(a.decision_base_done)~='boolean' or not valid_down_archive(a) or not json.isobject(a.ai_settings) or type(a.ai_settings.stop_on_rare)~='boolean' or type(a.ai_settings.stop_enemy_count)~='number' or a.ai_settings.stop_enemy_count<0 or a.ai_settings.stop_enemy_count>100 or a.ai_settings.stop_enemy_count~=math.floor(a.ai_settings.stop_enemy_count) or type(a.generation)~='number' or a.generation~=math.floor(a.generation) or a.generation<1 or a.generation>=9007199254740991 or type(a.seed)~='number' or a.seed~=math.floor(a.seed) or a.seed<0 or a.seed>2147483647 then reject(id,'incompatible_archive')
        else
            local ok,result=xpcall(function()
                local fresh=scenario.create(a.seed,a.fixture)
                local restored=snapshot.restore(a.snapshot,fresh)
                init_aioo()
                aioo.import_state(graph_codec.decode(a.provider_state,{},1000))
                config.settings.player_aioo_stop_on_rare=a.ai_settings.stop_on_rare
                config.settings.player_aioo_stop_enemy_count=a.ai_settings.stop_enemy_count
                return restored
            end,debug.traceback)
            if not ok then print(tostring(result)); send('{"id":'..sid..',"ok":false,"error":{"code":"restore_failed","outcome":"unknown"}}'); break end
            state=result; reset_health(); state_seed=a.seed; state_fixture=a.fixture; decision_base_done=a.decision_base_done; generation=math.max(a.generation+1,minimum)
            pending=a.pending_action; down_events={}; next_down_event=a.next_down_event; alarm_previous_paused=a.alarm_previous_paused
            if alarm_previous_paused==json.null then alarm_previous_paused=nil end
            for _,event in ipairs(a.down_events) do
                assert(json.isobject(event) and type(event.id)=='number' and event.id>=1 and event.id<next_down_event and type(event.actor_id)=='number', 'invalid down event')
                down_events[#down_events+1]={id=event.id,actor_id=event.actor_id,serial=event.serial,turn=event.turn}
            end
            bind_down_listener(false); refresh_visibility()
            reply(id,{accepted=true,generation=generation,boundary=#down_events>0 and 'input' or 'decision'})
        end
    elseif req.method=='dm_bind' then
        last_id=id
        if not state or state_fixture~='formal' or not dm_bind_allowed then reject(id,'binding_unavailable')
        elseif req.expected_generation~=generation then reject(id,'stale_generation')
        else
            local ok,result=xpcall(function() return require('dm_native').bind(state,req.params.members) end,debug.traceback)
            if ok then dm_bind_allowed=false; reply(id,result) else print(tostring(result)); reject(id,'invalid_binding') end
        end
    elseif req.method=='character_editor' then
        last_id=id
        if not state or state_fixture~='formal' then reject(id,'formal_required')
        elseif req.expected_generation~=generation then reject(id,'stale_generation')
        elseif pending or #down_events>0 or require('native_inputs').has_pending() or select(1,aioo.control())=='running' then reject(id,'not_paused')
        else
            local ok,result=xpcall(function()
                local p=req.params;local editor=require('character_editor')
                if p.operation=='open' then return editor.open(state,p.actor_id)
                elseif p.operation=='edit' then return editor.edit(state,p.actor_id,p.step)
                elseif p.operation=='finish' then return editor.finish(state,p.actor_id)
                elseif p.operation=='read' then return editor.read(state,p.actor_id)
                elseif p.operation=='describe' then return editor.describe(state,p.actor_id,p.talent_id)
                elseif p.operation=='attachments' then return require('campaign_loadout').attachments(state,p.actor_id,p.slot,p.position)
                elseif p.operation=='destinations' then return require('campaign_loadout').destinations(state,p.actor_id,p.item_id)
                elseif p.operation=='equipment' then
                    local request=p.request
                    require('campaign_loadout').apply(state,state._dm_items_world,request)
                    return require('dm_native').inspect(state)
                end
                error('unknown editor operation')
            end,debug.traceback)
            if ok then reply(id,result) else print(tostring(result));reject(id,'character_editor_rejected') end
        end
    elseif req.method=='loot_preview' then
        last_id=id
        if not state or state_fixture~='formal' then reject(id,'formal_required')
        elseif req.expected_generation~=generation then reject(id,'stale_generation')
        elseif state._plane_origin then reject(id,'inside_temporary_plane')
        elseif pending or require('rule_events').has_pending() or require('native_inputs').has_pending() or select(1,aioo.control())=='running' then reject(id,'not_paused')
        else
            local saved_rng=rng.state_get()
            local ok,items,coins=xpcall(function()
                if terminal=='defeat' then return require('json_validate').array(),0 end
                return require('localization').wrap(require('campaign_items').loot_preview)(state)
            end,debug.traceback)
            rng.state_set(saved_rng)
            if ok then
                local available=terminal~='defeat' and state.map~=nil and not state._dm_area_outside
                    and type(state._dm_current_area)=='string' and state._dm_current_area:sub(1,5)=='area:'
                reply(id,{items=items,coin_cents=coins,available=available})
            else print(tostring(items));reject(id,'loot_preview_unavailable') end
        end
    elseif req.method=='dm_inspect' then
        last_id=id
        if not state then reject(id,'not_created')
        elseif state_fixture~='formal' then reject(id,'formal_required')
        elseif req.expected_generation~=generation then reject(id,'stale_generation')
        else
            local ok,result=xpcall(function() local r=require('dm_native').inspect(state);r.local_areas=require('local_area').describe(state);r.world_people=require('scene_placement').people(state);return r end,debug.traceback)
            if ok then reply(id,result) else print(tostring(result)); reject(id,'dm_inspect_unavailable') end
        end
    elseif req.method=='respond_input' then
        last_id=id
        local inputs=require 'native_inputs'
        local valid,reason=inputs.validate(req.params)
        if not state then reject(id,'not_created')
        elseif req.expected_generation~=generation then reject(id,'stale_generation')
        elseif not valid then reject(id,reason)
        else
            local ok,result=xpcall(function()
                local owner=begin_manual_input(req.params.input_id)
                inputs.respond(req.params)
                if inputs.has_pending() then remember_manual_input(owner);refresh_visibility();return 'await_input' end
                publish_manual_post_frame(owner)
                if ai_input_task.active() then
                    local status,reason,spent,owner=ai_input_task.continue()
                    if status=='await_input' then refresh_visibility();return 'await_input' end
                    if status=='control_changed' then aioo.stop_owned(owner,'control_changed') else aioo.stop(reason) end
                    state.last_action={outcome=status=='control_changed' and 'native_control_changed' or status=='input_cancelled' and 'native_input_cancelled' or status=='input_declined' and 'native_input_declined' or status=='input_interrupted' and 'native_input_interrupted' or 'native_input_resolved',energy_spent=spent}
                    if state.player:enoughEnergy() then state.game.paused=true;decision_base_done=state.control_base_done~=false end
                end
                if state.game.paused and state.player:enoughEnergy() then refresh_visibility();return advance_to_boundary(0) end
                pending=true;return advance_to_boundary(30)
            end,debug.traceback)
            if not ok then print(tostring(result));send('{"id":'..sid..',"ok":false,"error":{"code":"input_failed","outcome":"unknown"}}');break end
            reply(id,{accepted=true,generation=generation,boundary=result})
        end
    elseif req.method=='campaign_wipeout' then
        last_id=id
        if not state or state_fixture~='formal' or terminal~='defeat' then reject(id,'terminal_defeat_required')
        elseif req.expected_generation~=generation then reject(id,'stale_generation')
        elseif pending or require('rule_events').has_pending() or require('native_inputs').has_pending() or select(1,aioo.control())=='running' then reject(id,'not_paused')
        else
            local before=state.game.turn
            local ok,result=xpcall(function()
                for i=1,16 do
                    local remains=(state.game.on_tick_end and next(state.game.on_tick_end.fcts)) or (state.game.on_tick_end_custom and next(state.game.on_tick_end_custom.fcts))
                    if not remains then break end
                    local selected=state.game.on_tick_end_custom or state.game.on_tick_end
                    assert(selected and #selected.fcts>0,'default callback blocked by custom queue')
                    local prior={};for _,fn in ipairs(selected.fcts) do prior[fn]=true end
                    state.game:onTickEndExecute();assert(state.game.turn==before,'callback advanced turn')
                    for _,set in ipairs({state.game.on_tick_end_custom or {},state.game.on_tick_end or {}}) do
                        for _,fn in ipairs(set.fcts or {}) do assert(not prior[fn],'rescheduled callback requires another tick') end
                    end
                    assert(not require('rule_events').has_pending() and not require('native_inputs').has_pending(),'callback requires input or rules')
                    assert(not next(state.game.__coroutines or {}),'callback started coroutine')
                    for _,a in ipairs(state.allies) do assert(not a.dead and rescue.is_down(a),'callback changed defeated party') end
                end
                assert(not (state.game.on_tick_end and next(state.game.on_tick_end.fcts)) and not (state.game.on_tick_end_custom and next(state.game.on_tick_end_custom.fcts)),'callback budget exhausted')
                return require('campaign_wipeout').apply(state,req.params.world_id,req.params.world_location,req.params.victor_id)
            end,debug.traceback)
            if not ok or state.game.turn~=before then print(tostring(result));send('{"id":'..sid..',"ok":false,"error":{"code":"campaign_wipeout_failed","outcome":"unknown"}}');break end
            down_events={};alarm_previous_paused=nil;state.game.paused=true;refresh_visibility()
            reply(id,{accepted=true,generation=generation,boundary='terminal',transition=result})
        end
    elseif req.method=='campaign_settle' then
        last_id=id
        if not state or state_fixture~='formal' or (not terminal and not state.campaign_bootstrap) then reject(id,'terminal_required')
        elseif req.expected_generation~=generation then reject(id,'stale_generation')
        elseif pending or (#down_events>0 and terminal~='defeat') or require('rule_events').has_pending() or require('native_inputs').has_pending() then reject(id,'not_paused')
        else
            local before=state.game.turn
            local defeated=terminal=='defeat'
            local ok,result=xpcall(function()
                state.game:onTickEndExecute()
                assert(state.game.turn==before,'settlement advanced turn')
                if defeated then
                    if not state._dm_wipeout then
                     for _,a in ipairs(state.allies)do assert(not a.dead and rescue.is_down(a),'callback changed defeated party') end
                    end
                    assert(not next(state.game.__coroutines) and not require('native_inputs').has_pending()
                        and not require('rule_events').has_pending(),'defeat callback suspended')
                end
                local remains=(state.game.on_tick_end and next(state.game.on_tick_end.fcts)) or (state.game.on_tick_end_custom and next(state.game.on_tick_end_custom.fcts))
                return json.object({remaining=not not remains})
            end,debug.traceback)
            if not ok then print(tostring(result));send('{"id":'..sid..',"ok":false,"error":{"code":"campaign_settlement_failed","outcome":"unknown"}}');break end
            if not defeated then terminal=nil end;refresh_visibility()
            local boundary=defeated and 'terminal' or advance_to_boundary(0)
            if boundary=='terminal' and not result.remaining then
                require('headless_visuals').dismiss_terminal(state.map)
            end
            reply(id,{accepted=true,generation=generation,boundary=boundary,transition=result})
        end
    elseif req.method=='campaign_adopt' then
        last_id=id
        if not state or state_fixture~='formal' then reject(id,'formal_required')
        elseif req.expected_generation~=generation then reject(id,'stale_generation')
        elseif pending or #down_events>0 or require('rule_events').has_pending() or require('native_inputs').has_pending() or select(1,aioo.control())=='running' then reject(id,'not_paused')
        else
            local before=state.game.turn
            local ok,result=xpcall(function() return require('campaign_items').adopt(state,req.params.world_id,req.params.campaign_id) end,debug.traceback)
            if not ok or state.game.turn~=before then print(tostring(result));send('{"id":'..sid..',"ok":false,"error":{"code":"campaign_adopt_failed","outcome":"unknown"}}');break end
            if state.map then refresh_visibility() end
            reply(id,{accepted=true,generation=generation,boundary=terminal and state.map and 'terminal' or 'decision',transition=result})
        end
    elseif req.method=='campaign_reconcile' then
        last_id=id
        if not state or state_fixture~='formal' then reject(id,'formal_required')
        elseif req.expected_generation~=generation then reject(id,'stale_generation')
        elseif pending or #down_events>0 or require('rule_events').has_pending() or require('native_inputs').has_pending() or select(1,aioo.control())=='running' then reject(id,'not_paused')
        else
            local before=state.game.turn
            local ok,result=xpcall(function() return require('campaign_items').reconcile(state,req.params.world_id,req.params.world_location,req.params.observation_id) end,debug.traceback)
            if not ok or state.game.turn~=before then print(tostring(result));send('{"id":'..sid..',"ok":false,"error":{"code":"campaign_reconcile_failed","outcome":"unknown"}}');break end
            if state.map then refresh_visibility() end
            reply(id,{accepted=true,generation=generation,boundary=terminal and state.map and 'terminal' or 'decision',transition=result})
        end
    elseif req.method=='campaign_items' then
        last_id=id
        if not state or state_fixture~='formal' then reject(id,'formal_required')
        elseif req.expected_generation~=generation then reject(id,'stale_generation')
        elseif pending or #down_events>0 or require('rule_events').has_pending() or require('native_inputs').has_pending() or select(1,aioo.control())=='running' then reject(id,'not_paused')
        else
            local before=state.game.turn
            local ok,result=xpcall(function()
                local reqitem=req.params.request
                local ground=reqitem and reqitem.operation=='add' and state._dm_ground_items and state._dm_ground_items[reqitem.item_id]
                if ground and ground.offline then
                    assert(partition_active and partition_reader and state._dm_area_outside,'cold ground requires authorized camp reader')
                    assert(req.params.world_id==state._dm_items_world and reqitem.source_location==ground.location,'cold ground scope mismatch')
                    require('native_save_partition_scene').materialize(state,partition_reader,ground.area_id,ground.floor,{next_uid=require('engine.Entity').native_uid_state()})
                end
                if reqitem and reqitem.operation=='company_join' then
                    assert(partition_active and partition_reader and state._dm_area_outside and not state.map,
                        'native company creation context unavailable')
                    local pid=reqitem.actor_id
                    local entry=(state._dm_world_person_index or {})[pid]
                    if entry and entry.area_id then
                        require('native_save_partition_scene').materialize(state,partition_reader,entry.area_id,entry.floor,
                            {next_uid=require('engine.Entity').native_uid_state()})
                    end
                    local zone,slot=require('native_save_partition_scene').materialize(state,partition_reader,
                        assert(state._dm_current_area),assert(state._dm_current_floor),{next_uid=require('engine.Entity').native_uid_state()})
                    local g=state.game
                    assert(not (g.on_tick_end and next(g.on_tick_end.fcts)) and not g.on_tick_end_custom,'native company birth has pending callbacks')
                    g.zone=zone;g.level=slot.level
                    local captured={};g:onTickEndCapture(captured)
                    local ok,value=xpcall(function()
                        local result=require('campaign_items').apply(state,req.params.world_id,reqitem)
                        local owned={}
                        for _,item in ipairs(result.adopted)do
                            owned[assert(state._dm_item_objects[item.item_id])]=true
                        end
                        flush_creation_callbacks(g,captured,function(item)return owned[item]end,state._dm_world_person_actors[pid])
                        return result
                    end,debug.traceback)
                    g:onTickEndCapture(nil);g.level=nil;g.zone=nil
                    if not ok then error(value)end
                    assert(not next(g.__coroutines) and not require('native_inputs').has_pending(),'company birth suspended')
                    return value
                end
                if reqitem and (reqitem.operation=='prepare_craft' or (reqitem.operation=='add' and reqitem.item_spec)) and state._dm_area_outside and not state.map then
                    assert(partition_active and partition_reader and not state.game.level and not state.game.zone,'native item factory context unavailable')
                    local area_id=assert(state._dm_current_area);local floor=assert(state._dm_current_floor)
                    local zone,slot=require('native_save_partition_scene').materialize(state,partition_reader,area_id,floor,{next_uid=require('engine.Entity').native_uid_state()})
                    local g=state.game
                    assert(not (g.on_tick_end and next(g.on_tick_end.fcts)) and not g.on_tick_end_custom,'native item factory has pending callbacks')
                    g.zone=zone;g.level=slot.level
                    local captured={};g:onTickEndCapture(captured)
                    local ok,value=xpcall(function()
                        local result=require('campaign_items').apply(state,req.params.world_id,reqitem)
                        local owned,actor={},nil
                        if reqitem.operation=='prepare_craft' then
                            for _,item in ipairs(result.adopted)do owned[assert(state._dm_item_objects[item.item_id])]=true end
                            for _,member in ipairs(require('company_roster').members(state))do
                                if member._dm_world_id==reqitem.actor_id then actor=member;break end
                            end
                        else
                            owned[assert(state._dm_item_objects[reqitem.item_id],'native created item missing')]=true
                        end
                        flush_creation_callbacks(g,captured,function(item)return owned[item]end,actor)
                        return result
                    end,debug.traceback)
                    g:onTickEndCapture(nil);g.level=nil;g.zone=nil
                    if not ok then error(value) end
                    return value
                end
                return require('campaign_items').apply(state,req.params.world_id,reqitem)
            end,debug.traceback)
            if not ok or state.game.turn~=before then print(tostring(result));send('{"id":'..sid..',"ok":false,"error":{"code":"campaign_items_failed","outcome":"unknown"}}');break end
            if state.map then refresh_visibility() end
            reply(id,{accepted=true,generation=generation,boundary=terminal and state.map and 'terminal' or 'decision',transition=result})
        end
    elseif req.method=='campaign_next' then
        last_id=id
        if not state or state_fixture~='formal' or (terminal~='victory' and not state.campaign_bootstrap and not (terminal=='defeat' and state._dm_wipeout)) then reject(id,'terminal_victory_required')
        elseif req.expected_generation~=generation then reject(id,'stale_generation')
        elseif pending or #down_events>0 or require('rule_events').has_pending() or require('native_inputs').has_pending() or select(1,aioo.control())=='running' then reject(id,'not_paused')
        elseif (state.game.on_tick_end and next(state.game.on_tick_end.fcts)) or (state.game.on_tick_end_custom and next(state.game.on_tick_end_custom.fcts)) then reject(id,'settlement_pending')
        else
            local ok,result=xpcall(function() return require('campaign_transition').apply(state,req.params) end,debug.traceback)
            if not ok then print(tostring(result));send('{"id":'..sid..',"ok":false,"error":{"code":"campaign_transition_failed","outcome":"unknown"}}');break end
            terminal=nil;nav={status='idle'};decision_base_done=false;reset_health();refresh_visibility();begin_progress()
            reply(id,{accepted=true,generation=generation,boundary=advance_to_boundary(0),transition=result})
        end
    elseif req.method=='dm_transition' then
        last_id=id
        local entering=req.params.operation=='area_enter'
        local departing=req.params.operation=='area_depart'
        local admin_entry=(entering or (departing and state and state._dm_area_outside)) and state and not state.game.paused and not terminal and #down_events==0
            and (state.campaign_bootstrap or state._dm_area_outside) and #state.allies>0
        if admin_entry then for _,a in ipairs(state.allies)do if not a._dm_world_id then admin_entry=false end end end
        if not state then reject(id,'not_created')
        elseif req.expected_generation~=generation then reject(id,'stale_generation')
        elseif state._plane_origin then reject(id,'inside_temporary_plane')
        elseif pending or require('rule_events').has_pending() or require('native_inputs').has_pending() or select(1,aioo.control())=='running' or nav.status=='running' or (not state.game.paused and not admin_entry) then reject(id,'not_paused')
        else
            local ok,result=xpcall(function()
                if entering then
                    assert(#down_events==0 and not rescue.progress(state.player),'area entry requires a settled party')
                    if partition_active then
                        local target=state._dm_local_areas and state._dm_local_areas[req.params.area.area_id]
                        local slot=target and target.floors[req.params.area.floor]
                        if target and (not target.zone or (slot and not slot.level)) then
                            assert(partition_reader,'authorized native partition reader missing')
                            if slot then require('native_save_partition_scene').materialize(state,partition_reader,req.params.area.area_id,req.params.area.floor,{next_uid=require('engine.Entity').native_uid_state()})
                            else require('native_save_partition_scene').materialize_zone(state,partition_reader,req.params.area.area_id,{next_uid=require('engine.Entity').native_uid_state()}) end
                        end
                    end
                    return require('local_area').enter(state,req.params.area)
                end
                if departing then
                    if partition_active then return require('local_area').park(state,req.params.area) end
                    return require('local_area').depart(state,req.params.area)
                end
                if req.params.operation=='spawn_enemy' and req.params.source_area and partition_reader then
                    require('native_save_partition_scene').materialize(state,partition_reader,req.params.source_area,req.params.source_floor,{next_uid=require('engine.Entity').native_uid_state()})
                end
                if req.params.operation=='spawn_enemy' then
                    return require('local_area').populate_scoped(state,function() return require('dm_transition').apply(state,req.params) end)
                end
                return require('dm_transition').apply(state,req.params)
            end,debug.traceback)
            if not ok then print(tostring(result));send('{"id":'..sid..',"ok":false,"error":{"code":"dm_transition_failed","outcome":"unknown"}}');break end
            if entering or departing then result=json.object(result);if result.refresh then result.refresh=json.object(result.refresh) end end
            if req.params.operation=='spawn_enemy' and result.status=='applied' and terminal=='victory' then terminal=nil end
            if entering then terminal=nil;state._dm_wipeout=nil;state.campaign_bootstrap=false;nav={status='idle'};decision_base_done=false;reset_health() end
            if state.map then refresh_visibility() end
            if entering then begin_progress() end
            local boundary=state.map and advance_to_boundary(0) or 'decision'
            reply(id,{accepted=true,generation=generation,boundary=boundary,transition=result})
        end
    elseif req.method=='scene_query' then
        last_id=id
        if not state then reject(id,'not_created')
        elseif req.expected_generation~=generation then reject(id,'stale_generation')
        else
            local ok,result=xpcall(function() return require('scene_placement').query(state,req.params) end,debug.traceback)
            if ok then reply(id,require('localization').with(require('localization').display,result))else print(tostring(result));reject(id,'scene_query_failed')end
        end
    elseif req.method=='content_catalog' then
        last_id=id
        if not state then reject(id,'not_created')
        elseif req.expected_generation~=generation then reject(id,'stale_generation')
        else
            local ok,result=xpcall(function() return require('native_catalog').read() end,debug.traceback)
            if ok then reply(id,result) else print(tostring(result));reject(id,'catalog_unavailable') end
        end
    elseif req.method=='inspect_actor' then
        last_id=id
        if not state then reject(id,'not_created')
        elseif req.expected_generation~=generation then reject(id,'stale_generation')
        else
            local result,reason=require('actor_inspection').read(state,req.params.target)
            if result then reply(id,result) else reject(id,reason) end
        end
    elseif req.method=='observe' then
        last_id=id
        if not state then reject(id,'not_created')
        elseif req.expected_generation and req.expected_generation~=generation then reject(id,'stale_generation')
        else reply(id,observe()) end
    elseif req.method=='reset' then
        last_id=id
        local seed=req.params.seed
        if not state then reject(id,'not_created')
        elseif req.expected_generation~=generation then reject(id,'stale_generation')
        elseif #down_events>0 then reject(id,'confirmation_required')
        elseif pending then reject(id,'pending')
        elseif type(seed)~='number' or seed<0 or seed>2147483647 or seed~=math.floor(seed) then reject(id,'invalid_seed')
        elseif generation>=9007199254740991 then reject(id,'generation_limit')
        else protocol_restart(seed,id,generation+1,state_fixture); return end
    elseif req.method=='act' and state and not state.map then
        last_id=id;reject(id,'outside_native_area')
    elseif req.method=='act' then
        dm_bind_allowed=false
        last_id=id
        local p=state and state.player
        local nav_step=req.params.type=='navigate_step'
        if state and req.expected_generation==generation and req.params.type~='navigate_step' and req.params.type~='navigate_start' and nav.status=='running' then
            nav.status='stopped'; nav.stop_reason='cancelled'
        end
        local dm_door=req.params.type=='dm_open_door'
        if dm_door then req.params.type='move' end
        local e, bump, door
        if state then
            for _,foe in ipairs(state.combatants or state.enemies) do
                if tostring(req.params.target)==tostring(foe.uid) then e=foe end
                if req.params.type=='move' and type(req.params.dx)=='number' and type(req.params.dy)=='number' and not foe.dead and state.player_visible[foe.uid] and foe.x==p.x+req.params.dx and foe.y==p.y+req.params.dy then bump=foe end
            end
            if req.params.type=='move' and type(req.params.dx)=='number' and type(req.params.dy)=='number' then
                for _,ally in ipairs(state.allies) do
                    if ally~=p and not ally.dead and not rescue.is_down(ally) and not ally.on_bump and not ally.can_talk and ally.x==p.x+req.params.dx and ally.y==p.y+req.params.dy then bump=ally end
                end
                local x,y=p.x+req.params.dx,p.y+req.params.dy
                if x>=0 and y>=0 and x<state.map.w and y<state.map.h and state.map.seens(x,y) then
                    local grid=state.map(x,y,state.Map.TERRAIN)
                    if grid and grid.door_opened and p.open_door and not grid.door_player_stop
                        and (not grid.door_player_check or (not dm_door and state.map.attrs(x,y,'vault_id')))
                        and not grid:check('block_move',x,y,p,false,true) then door=grid end
                end
            end
        end
        local item_check_ok,item_allowed,item_reason=true,nil,nil
        if state and req.expected_generation==generation and req.params.type=='use_item' then
            item_check_ok,item_allowed,item_reason=pcall(require('campaign_items').check_use,state,{actor_id=req.params.actor_id,slot=req.params.slot,pos=req.params.pos,uid=req.params.uid})
        end
        if not state then reject(id,'not_created')
        elseif req.expected_generation~=generation then reject(id,'stale_generation')
        elseif not item_check_ok then print(tostring(item_allowed));send('{"id":'..sid..',"ok":false,"error":{"code":"item_check_failed","outcome":"unknown"}}');break
        elseif req.params.type=='use_item' and not item_allowed then reject(id,item_reason or 'item_unavailable')
        elseif require('native_inputs').has_pending() and req.params.type~='ai_stop' then reject(id,'native_input_pending')
        elseif req.params.type=='confirm_down' then
            local event=down_events[1]
            if terminal or not event or req.params.generation~=generation or type(req.params.event_id)~='number' or req.params.event_id~=event.id then reject(id,'stale_down_event')
            else
                table.remove(down_events,1)
                require('rule_events').resume_after_confirmation()
                if #down_events==0 and alarm_previous_paused~=nil then state.game.paused=alarm_previous_paused; alarm_previous_paused=nil end
                reply(id,{accepted=true,generation=generation,boundary=#down_events>0 and 'input' or (pending and 'pending' or 'decision')})
            end
        elseif pending and req.params.type~='takeover' then reject(id,'pending')
        elseif state._plane_origin and (req.params.type=='takeover' or req.params.type=='return_control' or req.params.type=='rescue_start') then reject(id,'inside_temporary_plane')
        elseif #down_events>0 and req.params.type~='takeover' and req.params.type~='return_control' and req.params.type~='rescue_cancel' and req.params.type~='ai_stop' then reject(id,'confirmation_required')
        elseif not rescue_ready and (req.params.type=='takeover' or req.params.type=='return_control' or req.params.type=='rescue_start' or req.params.type=='rescue_step' or req.params.type=='rescue_cancel') then reject(id,'unsupported')
        elseif req.params.type=='native_control' then
            local target
            for _,a in ipairs(state.game.party.m_list)do if tostring(a.uid)==tostring(req.params.target)then target=a end end
            if terminal or rescue.progress(p) or not require('native_control').allowed(state,target) then reject(id,'invalid_native_control_target')
            else
                local ok,boundary=xpcall(function()
                    assert(state.game.party:setPlayer(target),'native party refused control')
                    state.player:doFOV();refresh_visibility()
                    if not state.player:enoughEnergy()then pending=true;return advance_to_boundary(30)end
                    return 'decision'
                end,debug.traceback)
                if not ok then print(tostring(boundary));send('{"id":'..sid..',"ok":false,"error":{"code":"control_failed","outcome":"unknown"}}');break end
                reply(id,{accepted=true,generation=generation,boundary=boundary})
            end
        elseif req.params.type=='takeover' or req.params.type=='return_control' then
            local target
            if req.params.type=='return_control' then target=state.allies[1]
            else for _,ally in ipairs(state.allies) do if tostring(ally.uid)==tostring(req.params.target) then target=ally end end end
            if (terminal and not (terminal=='victory' and req.params.type=='return_control')) or rescue.progress(p) or not target or target==p or target.dead or rescue.is_down(target) or (req.params.type=='takeover' and not (rescue.is_down(p) or (not require('native_control').is_core(state,p) and rescue.is_down(state.allies[1])))) or (req.params.type=='return_control' and (p==state.allies[1] or not require('native_control').is_core(state,p))) then reject(id,'invalid_control_target')
            else
                local ok,err=xpcall(function()
                    if rescue.progress(p) then rescue.cancel(p) end; aioo.stop('control_changed')
                    assert(state.game.party:setPlayer(target,true)); state.player=target
                    state.map.clean_fov=true; target:doFOV(); refresh_visibility()
                end,debug.traceback)
                if not ok then print(tostring(err)); send('{"id":'..sid..',"ok":false,"error":{"code":"control_failed","outcome":"unknown"}}'); break end
                local boundary=terminal and 'terminal' or 'decision'
                if #down_events>0 then if not target:enoughEnergy() then pending=true; alarm_previous_paused=false end; state.game.paused=true; boundary='input'
                elseif pending then boundary='pending'
                elseif not terminal and not target:enoughEnergy() then pending=true; boundary=advance_to_boundary(30) end
                reply(id,{accepted=true,generation=generation,boundary=boundary})
            end
        elseif req.params.type=='navigate_start' then
            local x,y=req.params.x,req.params.y
            if terminal or rescue.is_down(p) or rescue.progress(p) or aioo.is_active() then reject(id,'navigation_unavailable')
            elseif type(x)~='number' or type(y)~='number' or x~=math.floor(x) or y~=math.floor(y) or x<0 or y<0 or x>=state.map.w or y>=state.map.h or (x==p.x and y==p.y) or not state.navigation_memory[x+y*state.map.w] then reject(id,'invalid_navigation_target')
            else
                nav={status='running',x=x,y=y}
                reply(id,{accepted=true,generation=generation,boundary='decision'})
            end
        elseif nav_step and nav.status~='running' then reject(id,'navigation_not_authorized')
        elseif nav_step then
            local ok,boundary=xpcall(function()
                if require('rule_events').has_pending() then
                    require('rule_events').flush()
                    nav.status='stopped';nav.stop_reason='rule_events_settled'
                    state.last_action={outcome='rule_events_settled',energy_spent=false}
                    refresh_visibility();return advance_to_boundary(0)
                end
                if terminal or rescue.is_down(p) or rescue.progress(p) or aioo.is_active() or not p:enoughEnergy() then
                    nav.status='stopped'; nav.stop_reason='unavailable'; return 'decision'
                end
                local path=navigation.path(state,p,nav.x,nav.y)
                local nextpos=path and path[1]
                if not nextpos then nav.status='stopped'; nav.stop_reason='no_path'; return 'decision' end
                local x,y=nextpos.x,nextpos.y
                if math.max(math.abs(x-p.x),math.abs(y-p.y))~=1 then error('invalid native path') end
                -- A visible hostile or occupied tile must not turn navigation into an attack.
                for _,foe in ipairs(state.combatants or state.enemies) do
                    if not foe.dead and state.visible[foe.uid] and foe.x==x and foe.y==y then
                        nav.status='stopped'; nav.stop_reason='threat'; return 'decision'
                    end
                end
                local before_x,before_y,energy,life=p.x,p.y,p.energy.value,p.life
                local door_before
                if state.shared_seen[x+y*state.map.w] then
                    local grid=state.map(x,y,state.Map.TERRAIN)
                    if grid and grid.door_opened and p.open_door and not grid.door_player_check and not grid.door_player_stop then door_before=grid end
                end
                local had_threat=false
                for _,foe in ipairs(state.combatants or state.enemies) do if not foe.dead and state.visible[foe.uid] then had_threat=true end end
                local plane_frame=state._plane_origin and capture_manual_frame()
                local moved=p:move(x,y)
                local prior=p.did_energy==nil and moved==true and p.x==x and p.y==y and p.energy.value==energy
                local result='decision'
                if #down_events>0 and plane_frame then
                    publish_manual_post_frame(plane_frame);result=advance_to_boundary(0)
                elseif p.energy.value<energy then pending=true; result=advance_to_boundary(30)
                elseif prior then state.map.clean_fov=true; p:doFOV(); refresh_visibility()
                else state.map.clean_fov=true; p:doFOV(); refresh_visibility() end
                if #down_events>0 then nav.status='stopped'; nav.stop_reason='party_down'
                elseif result~='decision' or terminal then nav.status='stopped'; nav.stop_reason='boundary'
                elseif p.x==before_x and p.y==before_y and not (door_before and state.shared_seen[x+y*state.map.w] and state.map(x,y,state.Map.TERRAIN)~=door_before) then nav.status='stopped'; nav.stop_reason='blocked'
                elseif p.x==nav.x and p.y==nav.y then nav.status='stopped'; nav.stop_reason='arrived'
                elseif p.life<life then nav.status='stopped'; nav.stop_reason='danger'
                else
                    local threat=had_threat
                    for _,foe in ipairs(state.combatants or state.enemies) do if not foe.dead and state.visible[foe.uid] then threat=true end end
                    if threat then nav.status='stopped'; nav.stop_reason='threat' end
                end
                return result
            end,debug.traceback)
            if not ok then print(tostring(boundary)); send('{"id":'..sid..',"ok":false,"error":{"code":"navigation_failed","outcome":"unknown"}}'); break end
            reply(id,{accepted=true,generation=generation,boundary=boundary})
        elseif req.params.type=='ai_config' then
            local c=req.params.config
            if aioo.is_active() then reject(id,'ai_active')
            elseif not json.isobject(c) or type(c.stop_on_rare)~='boolean' or type(c.stop_enemy_count)~='number' or c.stop_enemy_count<0 or c.stop_enemy_count>100 or c.stop_enemy_count~=math.floor(c.stop_enemy_count) or not json.isobject(c.talent_weights) then reject(id,'invalid_ai_config')
            else
                local valid=true; local weights={}
                for key in pairs(c) do if key~='stop_on_rare' and key~='stop_enemy_count' and key~='talent_weights' then valid=false end end
                for tid,weight in pairs(c.talent_weights) do
                    local talent=type(tid)=='string' and p:knowTalent(tid) and p:getTalentFromId(tid)
                    if not talent or talent.mode=='passive' or type(weight)~='number' or weight~=weight or weight<0 or weight>10 then valid=false else weights[tid]=weight end
                end
                if not valid then reject(id,'invalid_ai_config')
                else
                    aioo.stop(); p.ai_talents=weights
                    config.settings.player_aioo_stop_on_rare=c.stop_on_rare
                    config.settings.player_aioo_stop_enemy_count=c.stop_enemy_count
                    local st,reason,epoch=aioo.control()
                    reply(id,{accepted=true,generation=generation,boundary='decision',ai_status=st,ai_stop_reason=reason,ai_epoch=epoch})
                end
            end
        elseif req.params.type=='ai_start' then
            local ai_status,_,ai_epoch=aioo.control()
            if rescue.progress(p) then reject(id,'rescue_active')
            elseif terminal or mission_complete() then reject(id,'terminal')
            elseif ai_status=='running' then reject(id,'ai_active')
            elseif p.dead or rescue.is_down(p) then reject(id,'actor_down')
            elseif req.params.mode~=nil and req.params.mode~='sweep' and req.params.mode~='explore' and req.params.mode~='rest' then reject(id,'invalid_ai_mode')
            elseif not acknowledge_health() then reject(id,'health_confirmation_required')
            else
                begin_progress()
                aioo.start(req.params.mode or 'sweep')
                ai_status,_,ai_epoch=aioo.control()
                reply(id,{accepted=true,generation=generation,boundary='decision',ai_status=ai_status,ai_stop_reason=json.null,ai_epoch=ai_epoch})
            end
        elseif req.params.type=='ai_stop' and req.params.reason~=nil and req.params.reason~='user' and req.params.reason~='budget' then reject(id,'invalid_stop_reason')
        elseif req.params.type=='ai_stop' then
            local reason=req.params.reason=='budget' and 'budget_exhausted' or 'user_stop'
            local ok,err=xpcall(function() if not ai_input_task.request_stop(reason) then aioo.stop(reason) end end,debug.traceback)
            if not ok then print(tostring(err)); send('{"id":'..sid..',"ok":false,"error":{"code":"ai_stop_failed","outcome":"unknown"}}'); break end
            local ai_status,reason,ai_epoch=aioo.control()
            if ai_input_task.active() then ai_status='stopped';reason='native_input_required' end
            reply(id,{accepted=true,generation=generation,boundary=ai_input_task.waiting() and 'await_input' or 'decision',ai_status=ai_status,ai_stop_reason=reason or json.null,ai_epoch=ai_epoch})
        elseif terminal then reject(id,'terminal')
        elseif p.dead or rescue.is_down(p) then reject(id,'actor_down')
        elseif rescue.progress(p) and req.params.type~='rescue_step' and req.params.type~='rescue_cancel' then reject(id,'rescue_active')
        elseif not p:enoughEnergy() then reject(id,'insufficient_energy')
        elseif req.params.type~='rescue_start' and req.params.type~='rescue_step' and req.params.type~='rescue_cancel' and req.params.type~='wait' and req.params.type~='move' and req.params.type~='talent' and req.params.type~='use_item' and req.params.type~='native_ai' and (req.params.type~='attack' or (req.params.mode~='melee' and req.params.mode~='ranged')) then reject(id,'unsupported')
        elseif req.params.type=='talent' and not native_actions.target_kind(req.params.talent) then reject(id,'unsupported_talent')
        elseif ((req.params.type=='talent' and native_actions.target_kind(req.params.talent)=='hostile') or (req.params.type=='attack' and req.params.mode=='ranged')) and (not e or e.dead or not state.player_visible[e.uid]) then reject(id,'invalid_target')
        elseif req.params.type=='talent' and native_actions.target_kind(req.params.talent)=='self' and req.params.target~=nil then reject(id,'invalid_target')
        elseif req.params.type=='talent' and native_actions.target_kind(req.params.talent)=='grid' and (type(req.params.x)~='number' or type(req.params.y)~='number' or req.params.x~=math.floor(req.params.x) or req.params.y~=math.floor(req.params.y) or req.params.x<0 or req.params.y<0 or req.params.x>=state.map.w or req.params.y>=state.map.h or not state.map.seens(req.params.x,req.params.y)) then reject(id,'invalid_target')
        elseif req.params.type=='attack' and req.params.mode=='melee' and (not e or e.dead or not state.player_visible[e.uid] or math.max(math.abs(p.x-e.x),math.abs(p.y-e.y))~=1) then reject(id,'invalid_target')
        elseif req.params.type=='move' and (type(req.params.dx)~='number' or type(req.params.dy)~='number' or req.params.dx~=math.floor(req.params.dx) or req.params.dy~=math.floor(req.params.dy) or math.max(math.abs(req.params.dx),math.abs(req.params.dy))~=1) then reject(id,'invalid_move')
        elseif dm_door and (not door or bump) then reject(id,'door_unavailable')
        elseif req.params.type=='move' and not bump and not door and not p:canMove(p.x+req.params.dx,p.y+req.params.dy) then reject(id,'blocked')
        elseif req.params.type=='native_ai' and (select(1,aioo.control())~='running' or req.params.ai_epoch~=select(3,aioo.control())) then reject(id,'ai_not_authorized')
        elseif req.params.type~='native_ai' and aioo.is_active() then reject(id,'ai_active')
        else
            local ok, boundary=xpcall(function()
                if require('rule_events').has_pending() then
                    require('rule_events').flush()
                    state.last_action={outcome='rule_events_settled',energy_spent=false}
                    refresh_visibility()
                    return advance_to_boundary(0)
                end
                local energy=p.energy.value
                local plane_frame=state._plane_origin and capture_manual_frame()
                local native_declined,manual_callback_queue=false,false
                state.last_action=nil
                local no_energy,was_active=false,nil
                local moved_on_prior_energy=false
                if req.params.type=='talent' then
                    local t=p:getTalentFromId(req.params.talent)
                    if t then
                        no_energy=not not util.getval(t.no_energy,p,t)
                        if t.mode=='sustained' then was_active=not not p:isTalentActive(t.id) end
                    end
                end
                if req.params.type=='rescue_start' or req.params.type=='rescue_step' or req.params.type=='rescue_cancel' then
                    local accepted,reason
                    if req.params.type=='rescue_start' then
                        local target; for _,ally in ipairs(state.allies) do if tostring(ally.uid)==tostring(req.params.target) then target=ally end end
                        if not target then return 'rejected:invalid_target' end
                        accepted,reason=rescue.start(p,target)
                    elseif req.params.type=='rescue_step' then accepted,reason=rescue.step(p)
                    else accepted,reason=rescue.cancel(p) end
                    if not accepted then return 'rejected:'..tostring(reason) end
                    if p.energy.value>=energy then refresh_visibility(); return advance_to_boundary(0) end
                elseif req.params.type=='use_item' then
                    local result=require('campaign_items').use(state,{actor_id=req.params.actor_id,slot=req.params.slot,pos=req.params.pos,uid=req.params.uid})
                    state.last_action={outcome='native_item_requested',energy_spent=result.energy_spent}
                    if result.input_pending then refresh_visibility();return 'await_input' end
                    if not result.energy_spent then refresh_visibility();return 'instant' end
                elseif req.params.type=='wait' then p:waitTurn()
                elseif req.params.type=='move' then
                    local x,y=p.x+req.params.dx,p.y+req.params.dy
                    local turn=state.game.turn
                    -- Combat:attackTarget can leave did_energy after AI melee. Actor:move
                    -- consumes that marker on the next displacement without a second charge.
                    local prior_energy=p.did_energy==true and not bump and not door
                    local moved=p:move(x,y)
                    moved_on_prior_energy=prior_energy and moved==true and p.x==x and p.y==y
                        and p.did_energy==nil and p.energy.value==energy and state.game.turn==turn and state.game.paused
                    if require('native_inputs').has_pending() then refresh_visibility();return 'await_input' end
                    if dm_door then p:waitTurn() end
                elseif req.params.type=='talent' or (req.params.type=='attack' and req.params.mode=='ranged') then
                    local accepted,reason
                    local owner=capture_manual_frame()
                    if req.params.type=='talent' then
                        local target=e
                        if native_actions.target_kind(req.params.talent)=='grid' then target={x=req.params.x,y=req.params.y} end
                        accepted,reason=native_actions.use(p,req.params.talent,target)
                    else accepted,reason=native_actions.shoot(p,e) end
                    if not accepted then return 'rejected:'..tostring(reason) end
                    if reason=='input_pending' then remember_manual_input(owner);refresh_visibility();return 'await_input' end
                    manual_callback_queue=publish_manual_post_frame(owner)
                    native_declined=reason=='native_declined'
                    if native_declined then state.last_action={outcome='native_declined',talent=req.params.talent or 'T_SHOOT',energy_spent=p.energy.value<energy} end
                elseif req.params.type=='native_ai' then
                    local function visible_danger()
                        if #down_events>0 or rescue.is_down(p) then return 'party_down' end
                        if aioo.mode()~='sweep' then for _,foe in ipairs(state.combatants or state.enemies) do if not foe.dead and state.visible[foe.uid] then return 'threat' end end end
                    end
                    if check_health() then aioo.stop('health_alert'); return 'ai:stopped' end
                    if aioo.mode()=='explore' then
                        local why=visible_danger()
                        if why then aioo.stop(why); return 'ai:stopped' end
                    end
                    local status,reason,spent,owner=ai_input_task.start(function()return aioo.lifecycle_step(req.params.ai_epoch,decision_base_done and state.control_base_done~=false,{
                        before=function(actor,x,y)
                            local why=visible_danger(); if why then return false,why end
                            local trap=state.map(x,y,state.Map.TRAP)
                            if trap and trap:knownBy(actor) and trap:canTrigger(x,y,actor,true) then return false,'trap' end
                            local entry=state.navigation_memory[x+y*state.map.w]
                            if not entry or entry.unsafe then return false,'danger' end
                            return true
                        end,
                        after=function(actor)
                            state.map.clean_fov=true; actor:doFOV(); refresh_visibility()
                            return visible_danger()
                        end,
                    })end,state.control_serial)
                    if status=='control_changed' then
                        aioo.stop_owned(owner,'control_changed')
                        state.last_action={outcome='native_control_changed',energy_spent=spent}
                        refresh_visibility();return advance_to_boundary(30)
                    end
                    if require('native_inputs').has_pending() then
                        if status~='await_input' or not ai_input_task.waiting() then error('native_ai_interactive_input_unverified') end
                        refresh_visibility();return 'await_input'
                    end
                    if #down_events>0 then if p.energy.value<energy then pending=true end; return advance_to_boundary(0) end
                    if status=='door_opened' then return 'instant' end
                    if status~='acted' then
                        if p.energy.value<energy then
                            local _,why=aioo.control();aioo.stop(why or status)
                            settling_stopped_ai=true;pending=true;return advance_to_boundary(30)
                        end
                        return 'ai:'..tostring(status)
                    end
                else p:move(e.x,e.y) end
                if #down_events>0 then
                    if plane_frame then publish_manual_post_frame(plane_frame) end
                    if p.energy.value<energy then pending=true end
                    return advance_to_boundary(0)
                end
                if p.energy.value>=energy then
                    if manual_callback_queue then refresh_visibility();return advance_to_boundary(0) end
                    if native_declined then refresh_visibility();return 'instant' end
                    if moved_on_prior_energy then
                        state.map.clean_fov=true; p:doFOV(); refresh_visibility(); return 'instant'
                    end
                    if req.params.type=='move' and door then
                        local now=state.map(p.x+req.params.dx,p.y+req.params.dy,state.Map.TERRAIN)
                        if now~=door then
                            state.map.clean_fov=true; p:doFOV(); refresh_visibility(); return 'instant'
                        end
                    end
                    if req.params.type=='talent' and (no_energy or was_active~=nil and was_active~=(not not p:isTalentActive(req.params.talent))) then
                        refresh_visibility(); return 'instant'
                    end
                    if req.params.type=='native_ai' then aioo.stop('no_action'); return 'ai:stopped' end
                    error('native action did not consume energy')
                end
                pending=true; return advance_to_boundary(30)
            end,debug.traceback)
            if not ok then print(tostring(boundary)); send('{"id":'..sid..',"ok":false,"error":{"code":"action_failed","outcome":"unknown"}}'); break end
            if boundary:sub(1,9)=='rejected:' then reject(id,boundary:sub(10))
            elseif boundary=='instant' then reply(id,{accepted=true,generation=generation,boundary='decision',action_kind='instant'})
            elseif boundary:sub(1,3)=='ai:' then local ai_status,reason,ai_epoch=aioo.control(); reply(id,{accepted=true,generation=generation,boundary='decision',ai_status=ai_status,ai_stop_reason=reason or json.null,ai_epoch=ai_epoch})
            else reply(id,{accepted=true,generation=generation,boundary=boundary}) end
        end
    elseif req.method=='advance' then
        dm_bind_allowed=false
        last_id=id
        local budget=req.params.budget
        if not state then reject(id,'not_created')
        elseif req.expected_generation~=generation then reject(id,'stale_generation')
        elseif not state.map then reject(id,'outside_native_area')
        elseif #down_events>0 then reject(id,'confirmation_required')
        elseif not pending then reject(id,'not_pending')
        elseif type(budget)~='number' or budget~=math.floor(budget) or budget<1 or budget>100 then reject(id,'invalid_budget')
        else
            local ok,boundary=xpcall(function() return advance_to_boundary(budget) end,debug.traceback)
            if not ok then print(tostring(boundary)); send('{"id":'..sid..',"ok":false,"error":{"code":"advance_failed","outcome":"unknown"}}'); break end
            reply(id,{accepted=true,generation=generation,boundary=boundary})
        end
    else
        last_id=id
        send('{"id":'..sid..',"ok":false,"error":{"code":"unsupported","outcome":"rejected"}}')
    end
end
