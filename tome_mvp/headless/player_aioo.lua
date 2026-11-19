-- Player AIoo runs through an explicit host-authorized controller.
-- The addon runs on a proxy class so its automatic Player.act hook cannot run
-- behind the host's back. The host must validate every control boundary.
local M = {}
local function upvalue(fn, wanted)
    for i=1,100 do
        local name, value = debug.getupvalue(fn, i)
        if not name then break end
        if name == wanted then return value end
    end
    error('AIoo missing expected upvalue: '..wanted)
end
local function load_chunk(chunk, player_class, budget_limit, host_health_policy)
    assert(type(chunk) == 'function' and type(player_class) == 'table')
    local proxy = setmetatable({}, {__index=player_class})
    local env = setmetatable({loadPrevious=function() return proxy end, headless_health_guard=function() return not host_health_policy end}, {__index=_G})
    setfenv(chunk, env)
    local result = chunk('mod.class.Player')
    assert(result == proxy and type(proxy.player_ai_start) == 'function')
    local step = upvalue(proxy.player_ai_start, 'player_ai_act')
    local stop = upvalue(proxy.player_ai_start, 'aiStop')
    local hostiles = upvalue(step, 'spotHostiles')
    local validate_rest = upvalue(step, 'validateRest')
    local cleanup_owner
    local stop_env=getfenv(stop)
    local stop_game=setmetatable({}, {__index=function(_,key)
        if key=='player' and cleanup_owner then return cleanup_owner end
        return game[key]
    end,__newindex=function(_,key,value)game[key]=value end})
    setfenv(stop,setmetatable({game=stop_game},{__index=stop_env,__newindex=stop_env}))
    assert(type(step)=='function' and type(stop)=='function' and type(hostiles)=='function')
    budget_limit = budget_limit or 1000
    assert(type(budget_limit)=="number" and budget_limit >= 1)
    local started = false
    local deferred_rest = nil
    local status, stop_reason, epoch = 'idle', nil, 0
    local mode = nil
    local native_interrupt, explore_replan = nil, false
    local hooked_player, saved_run_stop, saved_rest_stop
    local function remove_interrupt_hooks()
        deferred_rest=nil
        if hooked_player then
            if hooked_player.running_prev and hooked_player.running_prev.dialog and hooked_player.running_prev.dialog.__headless_aioo_progress then hooked_player.running_prev.dialog=nil end
            hooked_player.runStop=saved_run_stop; hooked_player.restStop=saved_rest_stop
            hooked_player=nil; saved_run_stop=nil; saved_rest_stop=nil
        end
    end
    local function install_interrupt_hooks(p)
        if hooked_player==p then return end
        remove_interrupt_hooks()
        hooked_player=p
        saved_run_stop=rawget(p,'runStop'); saved_rest_stop=rawget(p,'restStop')
        local run_stop,rest_stop=p.runStop,p.restStop
        p.runStop=function(self,reason,...)
            if status=='running' and mode=='explore' and self.running then native_interrupt=reason or 'native_run_stop'; explore_replan=false end
            return run_stop(self,reason,...)
        end
        p.restStop=function(self,reason,...)
            if status=='running' and mode=='rest' and self.resting then native_interrupt=reason or 'rest_complete' end
            return rest_stop(self,reason,...)
        end
    end
    local function settle_interrupt()
        if status=='running' and native_interrupt then
            status='stopped'; stop_reason=native_interrupt; native_interrupt=nil; started=false; explore_replan=false
            remove_interrupt_hooks()
            return true
        end
        return false
    end
    local function replace_upvalue(fn, wanted, value)
        for i=1,100 do
            local name=debug.getupvalue(fn,i)
            if not name then break end
            if name==wanted then debug.setupvalue(fn,i,value); return end
        end
        error('AIoo missing expected upvalue: '..wanted)
    end
    local function observed_stop(reason)
        stop_reason = reason or 'AIoo stopped'
        status = 'stopped'
        return stop(reason)
    end
    -- Party health episodes are checked by the host at decision boundaries.
    if host_health_policy then replace_upvalue(step,'lowHealth',function() return false end) end
    replace_upvalue(step,'aiStop',observed_stop)
    replace_upvalue(proxy.player_ai_start,'aiStop',observed_stop)
    assert(upvalue(proxy.act,'old_act')==player_class.act, 'unexpected AIoo Player.act binding')
    replace_upvalue(proxy.act,'old_act',function() end) -- scheduler already ran Player.act
    local function call_bounded(fn)
        local previous, mask, count = debug.gethook()
        local budget = 0
        debug.sethook(function()
            budget = budget + 1
            if budget > budget_limit then error('AIoo instruction budget exceeded; outcome unknown') end
        end, '', 10000)
        local ok, result = xpcall(fn, debug.traceback)
        debug.sethook(previous, mask, count)
        if not ok then error(result) end
        return result
    end
    local function start(requested_mode)
        requested_mode=requested_mode or 'sweep'
        assert(requested_mode=='sweep' or requested_mode=='explore' or requested_mode=='rest', 'invalid automation mode')
        mode=requested_mode
        install_interrupt_hooks(game.player)
        native_interrupt=nil; explore_replan=false
        assert(status ~= 'running', 'AIoo already running')
        epoch=epoch+1; status='running'; stop_reason=nil; started=false
    end
    local function combat_step(request_epoch)
        assert(status=='running' and request_epoch==epoch, 'AIoo not authorized')
        local seen = call_bounded(function() return hostiles(game.player, true) end)
        if #seen == 0 then
            if started and proxy.ai_active then call_bounded(function() stop('AIoo combat scope ended') end) end
            started = false; status='stopped'; stop_reason='combat_scope_ended'; remove_interrupt_hooks()
            return 'combat_scope_ended'
        end
        if not started then
            started = true
            call_bounded(function() proxy:player_ai_start() end)
        else
            call_bounded(function() proxy:act() end)
        end
        if not proxy.ai_active then started = false; status='stopped'; stop_reason=stop_reason or 'plugin_stopped'; remove_interrupt_hooks(); return 'stopped' end
        return 'acted'
    end
    -- One authorized original REST, EXPLORE or FIGHT action.
    local function lifecycle_step(request_epoch, decision_base_done, door_hooks)
        assert(status=='running' and request_epoch==epoch, 'AIoo not authorized')
        if settle_interrupt() then return 'stopped' end
        local p=game.player
        local rest_energy,rest_turn=p.energy.value,game.turn
        local rest_callbacks=0
        local raw_rest_stop=rawget(p,'restStop'); local original_rest_stop=p.restStop
        p.restStop=function(self,...)
            local resting=self.resting
            local callback=resting and resting.on_very_end
            if callback==validate_rest then
                resting.on_very_end=function(...)
                    if rest_callbacks>=1 then deferred_rest={...};return end
                    rest_callbacks=rest_callbacks+1
                    return validate_rest(...)
                end
            end
            local result={original_rest_stop(self,...)}
            if resting and callback==validate_rest then resting.on_very_end=callback end
            return unpack(result)
        end
        local raw_act=rawget(p,'act'); local raw_auto=rawget(p,'autoExplore')
        local raw_run=rawget(p,'runStep'); local original_run=p.runStep
        local raw_stop=rawget(p,'runStop'); local original_stop=p.runStop
        local raw_check=rawget(p,'runCheck'); local original_check=p.runCheck
        local function ordinary_ground_object(self)
            if mode~='sweep' or self~=game.player then return nil end
            local map=game.level.map; local x,y=self.x,self.y
            if not map.seens(x,y) or map(x,y,map.ACTOR)~=self then return nil end
            local total=map:getObjectTotal(x,y)
            if not total or total<1 then return nil end
            local equipment={weapon=true,armor=true,ammo=true,jewelry=true}
            for i=1,total do
                local object=map:getObject(x,y,i)
                if not object or not equipment[object.type] or object.quest or object.lore or object.force_lore_artifact or object.auto_pickup or object.store or rawget(object,'on_pickup') or rawget(object,'on_prepickup') then return nil end
            end
            local seen=map.attrs(x,y,'obj_seen')
            if seen~=nil and seen~=true and seen~=self then return nil end
            return map,x,y
        end
        if mode=='sweep' then
            p.runCheck=function(self,ignore_memory,...)
                if ignore_memory then return original_check(self,ignore_memory,...) end
                local map,x,y=ordinary_ground_object(self)
                if not map then return original_check(self,ignore_memory,...) end
                local args={...}; map.attrs(x,y,'obj_seen',self)
                local ok,allowed,reason=xpcall(function() return original_check(self,ignore_memory,unpack(args)) end,debug.traceback)
                map.attrs(x,y,'obj_seen',true)
                if not ok then error(allowed) end
                return allowed,reason
            end
        end
        local original_auto=p.autoExplore; local deferred_door
        local opened_door=false; local guarded_stop=nil
        if door_hooks then
            p.runStop=function(self,msg,...)
                local site=debug.getinfo(2,'fSl')
                if msg=='at door' and site and site.func==original_auto and site.currentline==2453 and site.short_src=='/mod/class/interface/PlayerExplore.lua' then
                    local path,kind
                    for i=1,120 do
                        local name,value=debug.getlocal(2,i); if not name then break end
                        if name=='path' then path=value elseif name=='target_type' then kind=value end
                    end
                    local node=type(path)=='table' and #path==1 and path[1]
                    local x,y=node and node.x,node and node.y
                    local map=game.level.map
                    if kind=='door' and x and y and math.max(math.abs(x-self.x),math.abs(y-self.y))==1 and map.seens(x,y) then
                        local grid=map(x,y,map.TERRAIN)
                        if grid and grid.door_opened and self.open_door and not grid.door_player_check and not grid.door_player_stop then
                            local can,reason=self:runCheck()
                            if not can then guarded_stop=reason or 'native_run_stop'
                            else
                                local permitted,why=door_hooks.before(self,x,y)
                                if permitted then deferred_door={x=x,y=y,grid=grid,actor=self,px=self.x,py=self.y,energy=self.energy.value,turn=game.turn}
                                else guarded_stop=why or 'danger' end
                            end
                        end
                    end
                end
                return original_stop(self,msg,...)
            end
            p.runStep=function(self,...)
                if opened_door or guarded_stop or deferred_door then return false end
                local running=self.running
                local path=running and running.explore and running.path
                local node=path and path[running.cnt]
                local exhausted=path and running.explore=='door' and running.cnt==#path+1
                if exhausted then node=running.target end
                local map=game.level.map
                local x,y=node and node.x,node and node.y
                if x and y and math.max(math.abs(x-self.x),math.abs(y-self.y))==1 and map.seens(x,y) then
                    local grid=map(x,y,map.TERRAIN)
                    if grid and grid.door_opened and (grid.door_player_check or grid.door_player_stop or not self.open_door) then
                        guarded_stop='door_requires_input'; self:runStop(guarded_stop); return false
                    end
                    if grid and grid.door_opened and self.open_door then
                        local can,reason=self:runCheck()
                        if not can then guarded_stop=reason or 'native_run_stop'; self:runStop(reason); return false end
                        local permitted,why=door_hooks.before(self,x,y)
                        if not permitted then guarded_stop=why or 'danger'; self:runStop(guarded_stop); return false end
                        local expected=type(grid.door_opened)=='string' and game.zone.grid_list[grid.door_opened] or grid.door_opened
                        assert(expected,'unknown native door target')
                        local ox,oy,energy=self.x,self.y,self.energy.value
                        self:move(x,y)
                        assert(self.x==ox and self.y==oy and self.energy.value==energy and map(x,y,map.TERRAIN)==expected, 'unexpected native door result')
                        if exhausted and self.running then self:runStop('opened door') end
                        opened_door=true
                        guarded_stop=door_hooks.after(self,x,y)
                        return false
                    end
                end
                return original_run(self,...)
            end
        end
        local no_explore_target=false
        p.autoExplore=function(self,...)
            local was_running=self.running~=nil
            local map,x,y=ordinary_ground_object(self)
            if map then map.attrs(x,y,'obj_seen',true) end
            local result=original_auto(self,...)
            if result==false and ((not was_running and not self.running) or (was_running and self.running)) then no_explore_target=true end
            return result
        end
        local Dialog=require('engine.ui.Dialog')
        local popup=Dialog.simplePopup
        Dialog.simplePopup=function(self,title,text,callback,...)
            if (title=='Resting...' and text=='You are resting, press Enter to stop.') or
               (title=='Running...' and text=='You are exploring, press any key to stop.') then
                return {__headless_aioo_progress=true}
            end
            error('unclassified_dialog:'..tostring(title))
        end
        local base_already_run=decision_base_done==true
        local task=require 'ai_input_task'
        local guarded={}
        local planner_log=config.settings.log_detail_ai
        local planner_advanced,planner_tactical,planner_tactic=p.ai_state._advanced_ai,p.ai_state._imp_tactical,p.ai_state.tactic
        for _,name in ipairs({'useTalent','forceUseTalent','attackTarget','move','waitTurn','fireTalentCheck','autoExplore','runStep','restStep'})do
            local key=name;local original=p[key];local raw=rawget(p,key);local wrapper
            if type(original)=='function' then
                wrapper=function(self,...)
                    local fn=original
                    if raw==nil then
                        local index=getmetatable(self).__index
                        fn=type(index)=='table' and index[key] or index(self,key)
                    end
                    assert(fn~=wrapper,'recursive AI action guard')
                    return task.run_action(fn,self,...)
                end
                guarded[#guarded+1]={key=key,raw=raw,wrapper=wrapper};p[key]=wrapper
            end
        end
        p.act=function(self)
            if not base_already_run then base_already_run=true; task.run_action(player_class.act,self) end
            if not opened_door and not guarded_stop and not deferred_door and self:enoughEnergy() then proxy:act() end
        end
        local ok,result=xpcall(function()
            return call_bounded(function()
                if mode=='rest' then
                    if not started then started=true; p:restInit() elseif p.resting then p:restStep() end
                elseif mode=='explore' then
                    if not started then started=true; p:autoExplore()
                    elseif p.running then p:runStep()
                    elseif explore_replan then explore_replan=false; p:autoExplore()
                    else native_interrupt=native_interrupt or 'native_run_stop' end
                elseif deferred_rest then local pending=deferred_rest; deferred_rest=nil; base_already_run=true; rest_callbacks=rest_callbacks+1; validate_rest(unpack(pending))
                elseif not started then started=true; proxy:player_ai_start()
                elseif p.resting then p:restStep()
                elseif p.running then
                    local energy_before=p.energy.value
                    local map,x,y=ordinary_ground_object(p)
                    local target=p.running.target
                    if map and p.running.explore=='object' and target and target.x==x and target.y==y then
                        local allowed,reason=p:runCheck()
                        if not allowed then
                            guarded_stop=reason or 'native_run_stop'; p:runStop(guarded_stop)
                        else
                            local old_path=p.running.path
                            map.attrs(x,y,'obj_seen',true)
                            local replanned=p:autoExplore()
                            local running=p.running; local node=running and running.path and running.path[running.cnt]
                            if replanned==true and p.x==x and p.y==y and p.energy.value==energy_before and running and running.path~=old_path and node and math.max(math.abs(node.x-x),math.abs(node.y-y))==1 and not opened_door and not guarded_stop and not deferred_door then
                                p:runStep()
                            end
                        end
                    else p:runStep() end
                    if not p.running and not opened_door and not guarded_stop and not deferred_door and p.energy.value==energy_before and #hostiles(p,true)>0 then
                        proxy:act()
                    end
                else proxy:act() end
            end)
        end,debug.traceback)
        for i=#guarded,1,-1 do local g=guarded[i];if rawget(p,g.key)==g.wrapper then p[g.key]=g.raw end end
        p.act=raw_act; p.autoExplore=raw_auto; p.runStep=raw_run; p.runStop=raw_stop; p.restStop=raw_rest_stop; p.runCheck=raw_check; Dialog.simplePopup=popup
        if not ok then
            if result==task.CANCEL then
                config.settings.log_detail_ai=planner_log
                p.ai_state._advanced_ai=planner_advanced;p.ai_state._imp_tactical=planner_tactical;p.ai_state.tactic=planner_tactic
                return task.outcome()
            end
            error(result)
        end
        if (mode~='sweep' or proxy.ai_active) and deferred_door and not opened_door and not guarded_stop then
            local d=deferred_door; local map=game.level.map
            if d.actor==p and p.x==d.px and p.y==d.py and p.energy.value==d.energy and game.turn==d.turn and map.seens(d.x,d.y) and map(d.x,d.y,map.TERRAIN)==d.grid then
                local permitted,why=door_hooks.before(p,d.x,d.y)
                if permitted then
                    local expected=type(d.grid.door_opened)=='string' and game.zone.grid_list[d.grid.door_opened] or d.grid.door_opened
                    assert(expected,'unknown native door target')
                    p:move(d.x,d.y)
                    assert(p.x==d.px and p.y==d.py and p.energy.value==d.energy and map(d.x,d.y,map.TERRAIN)==expected,'unexpected native door result')
                    opened_door=true; guarded_stop=door_hooks.after(p,d.x,d.y)
                else guarded_stop=why or 'danger' end
            end
        end
        if mode=='explore' and opened_door and not guarded_stop then
            native_interrupt=nil; explore_replan=not p.running
        end
        if settle_interrupt() then return 'stopped' end
        if mode=='sweep' and not proxy.ai_active then started=false; status='stopped'; stop_reason=stop_reason or 'plugin_stopped'; remove_interrupt_hooks(); return 'stopped' end
        if mode=='rest' and not p.resting then started=false; status='stopped'; stop_reason='rest_complete'; remove_interrupt_hooks(); return 'stopped' end
        if deferred_rest and p.energy.value==rest_energy and game.turn==rest_turn then
            deferred_rest=nil;guarded_stop='rest_no_progress'
        end
        if guarded_stop then
            if p.running then p:runStop(guarded_stop) end
            if mode=='sweep' then call_bounded(function() stop(guarded_stop) end) end
            started=false; status='stopped'; stop_reason=guarded_stop; remove_interrupt_hooks()
            return 'stopped'
        end
        if opened_door then return 'door_opened' end
        if no_explore_target then
            if mode=='sweep' then call_bounded(function() stop('AIoo exploration has no reachable target') end) end
            started=false; status='stopped'; stop_reason='exploration_no_target'; remove_interrupt_hooks()
            return 'stopped'
        end
        return 'acted'
    end
    local function scalar_upvalue(fn, name)
        for i=1,100 do
            local k,v=debug.getupvalue(fn,i)
            if not k then break end
            if k==name then
                assert(type(v)=='number' and v==v and math.abs(v)<math.huge, 'invalid AIoo upvalue '..name)
                return i,v
            end
        end
        error('missing AIoo upvalue '..name)
    end
    local function native_turn_count() local _,value=scalar_upvalue(stop,'aiTurnCount'); return value end
    local function progress_reset()
        assert(mode=='sweep' and status=='running', 'progress reset requires running sweep')
        local i=scalar_upvalue(stop,'aiTurnCount'); debug.setupvalue(stop,i,0)
    end
    local function copy_data(v, seen, depth)
        local typ=type(v)
        if typ=='boolean' or typ=='string' then return v end
        if typ=='number' then assert(v==v and math.abs(v)<math.huge); return v end
        assert(typ=='table' and depth<12 and not seen[v], 'unsupported AIoo state')
        seen[v]=true
        local out={}
        for k,item in pairs(v) do
            assert((type(k)=='string' or (type(k)=='number' and k>=1 and k==math.floor(k))), 'unsupported AIoo key')
            out[k]=copy_data(item,seen,depth+1)
        end
        seen[v]=nil
        return out
    end
    local fields={'LastLife','firstChangeAi','noMoreRange','AI_talentfailed'}
    local function export_state()
        assert(not started and not proxy.ai_active, 'AIoo must be stopped before save')
        local _,ai_state=scalar_upvalue(step,'ai_state')
        local _,moy=scalar_upvalue(step,'moyRange')
        local _,turns=scalar_upvalue(stop,'aiTurnCount')
        local _,hunt=scalar_upvalue(stop,'hunt_start')
        assert(ai_state==0 and turns==0 and hunt==0, 'AIoo stop state invalid')
        local data={format='player-aioo-fight-state-v1',ai_state=ai_state,moyRange=moy,
                    aiTurnCount=turns,hunt_start=hunt,fields={},control_status=status,stop_reason=stop_reason,epoch=epoch}
        for _,key in ipairs(fields) do
            local value=rawget(proxy,key)
            if value~=nil then data.fields[key]=copy_data(value,{},0) end
        end
        return data
    end
    local function import_state(data)
        assert(not started and not proxy.ai_active and type(data)=='table' and data.format=='player-aioo-fight-state-v1')
        local allowed={format=true,ai_state=true,moyRange=true,aiTurnCount=true,hunt_start=true,fields=true,control_status=true,stop_reason=true,epoch=true}
        for key in pairs(data) do assert(allowed[key], 'unknown AIoo state field') end
        assert(data.ai_state==0 and data.aiTurnCount==0 and data.hunt_start==0, 'AIoo state must be stopped')
        assert(type(data.moyRange)=='number' and data.moyRange==data.moyRange and math.abs(data.moyRange)<math.huge)
        assert(type(data.fields)=='table')
        local fieldset={}; for _,key in ipairs(fields) do fieldset[key]=true end
        for key in pairs(data.fields) do assert(fieldset[key], 'unknown AIoo proxy field') end
        local clean=copy_data(data.fields,{},0)
        for _,key in ipairs(fields) do proxy[key]=clean[key] end
        local i=scalar_upvalue(step,'ai_state'); debug.setupvalue(step,i,data.ai_state)
        i=scalar_upvalue(step,'moyRange'); debug.setupvalue(step,i,data.moyRange)
        i=scalar_upvalue(stop,'aiTurnCount'); debug.setupvalue(stop,i,data.aiTurnCount)
        i=scalar_upvalue(stop,'hunt_start'); debug.setupvalue(stop,i,data.hunt_start)
        proxy.ai_active=false
        assert(data.control_status=='idle' or data.control_status=='stopped', 'invalid AIoo control status')
        assert(type(data.epoch)=='number' and data.epoch>=0 and data.epoch==math.floor(data.epoch), 'invalid AIoo epoch')
        assert(data.stop_reason==nil or type(data.stop_reason)=='string', 'invalid AIoo stop reason')
        status=data.control_status; stop_reason=data.stop_reason; epoch=data.epoch
    end
    local function guard_tick(fn)
        local p=game.player; local rest=rawget(p,'restStep'); local run=rawget(p,'runStep')
        local resting=p.resting; local callback=resting and resting.on_very_end
        if resting then
            assert(resting.dialog and resting.dialog.__headless_aioo_progress and (callback==validate_rest or (mode=='rest' and callback==nil)), 'unclassified resting callback')
            if callback==validate_rest then resting.on_very_end=function(...) deferred_rest={...} end end
        end
        p.restStep=function() return false end; p.runStep=function() return false end
        local ok,err=xpcall(fn,debug.traceback)
        p.restStep=rest; p.runStep=run
        if resting and p.resting==resting then resting.on_very_end=callback end
        if not ok then error(err) end
    end
    local function phase()
        if status~='running' or not started then return nil end
        if mode~='sweep' then return mode end
        local _,n=scalar_upvalue(step,'ai_state')
        return ({[0]='rest',[1]='explore',[2]='hunt',[3]='fight'})[n]
    end
    local function cancel(reason,owner)
        if started and proxy.ai_active then call_bounded(function() stop('AIoo stopped by user') end) end
        local p=owner or game.player
        if p.resting then
            assert(p.resting.dialog and p.resting.dialog.__headless_aioo_progress and (p.resting.on_very_end==validate_rest or (mode=='rest' and p.resting.on_very_end==nil)), 'unclassified resting state')
            p.resting.on_very_end=nil; p:restStop('AIoo stopped')
        end
        if p.running then
            assert(p.running.dialog and p.running.dialog.__headless_aioo_progress, 'unclassified running state')
            p:runStop('AIoo stopped')
        end
        if p.running_prev and p.running_prev.dialog and p.running_prev.dialog.__headless_aioo_progress then p.running_prev.dialog=nil end
        deferred_rest=nil; native_interrupt=nil; explore_replan=false; started = false; status='stopped'; stop_reason=reason or 'user_stop'; remove_interrupt_hooks()
    end
    local function stop_owned(owner,reason)
        assert(not cleanup_owner,'nested AI owner cleanup')
        cleanup_owner=owner
        local ok,err=xpcall(function()cancel(reason,owner)end,debug.traceback)
        cleanup_owner=nil
        if not ok then error(err)end
    end
    local function prepare_control_switch(owner)
        local rest=owner.resting
        if rest and rest.dialog and rest.dialog.__headless_aioo_progress and rest.on_very_end==validate_rest then
            rest.on_very_end=nil
            return function(changed)if not changed and owner.resting==rest and rest.on_very_end==nil then rest.on_very_end=validate_rest end end
        end
    end
    return {class=proxy, settle_interrupt=settle_interrupt, native_turn_count=native_turn_count, progress_reset=progress_reset, mode=function() return mode end, start=start, combat_step=combat_step, lifecycle_step=lifecycle_step, guard_tick=guard_tick, phase=phase, stop=cancel, stop_owned=stop_owned, prepare_control_switch=prepare_control_switch, control=function() return status,stop_reason,epoch end, is_active=function() return status=='running' or started or proxy.ai_active==true end, export_state=export_state, import_state=import_state}
end
-- Lua 5.1 protected calls in the AI scheduler must propagate a native input
-- yield. This environment is local to these controller closures.
local controller_env=getfenv(load_chunk)
local function protected_controller(call,handler)
    if require('ai_input_task').is_current() then return require('yieldable_talents').protected(call,handler) end
    return xpcall(call,handler)
end
setfenv(load_chunk,setmetatable({xpcall=protected_controller},{__index=controller_env,__newindex=controller_env}))
function M.load(path, player_class, budget_limit, host_health_policy)
    assert(type(path)=='string')
    local file,err=io.open(path,'rb')
    assert(file,err)
    local source=file:read('*a'); file:close()
    return M.load_source(source,player_class,budget_limit,host_health_policy)
end
function M.load_source(source, player_class, budget_limit, host_health_policy)
    assert(type(source)=='string')
    assert(type(headless_aioo_source)=='function' and source==headless_aioo_source(), 'unverified AIoo source')
    local original='game.player.life < game.player.max_life*0.20'
    local count
    source,count=source:gsub(original:gsub('([^%w])','%%%1'), '('..original..' and headless_health_guard())')
    assert(count==2, 'unexpected AIoo inline health guards')
    local chunk,err=loadstring(source,'@player_aioo_verified_original.lua')
    assert(chunk,err)
    return load_chunk(chunk,player_class,budget_limit,host_health_policy)
end
return M
