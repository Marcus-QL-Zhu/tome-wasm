-- Unexposed experiment. Do not treat this module as a save/restore API.
local codec=require 'graph_codec'
local json=require 'json_validate'
local M={}
local function bindings(state)
    local byvalue,byname={},{}
    local function anchor(v,name)
        if v~=nil and not byvalue[v] then byvalue[v]=name; byname[name]=v end
    end
    local seen={}
    local supported_classes={['mod.class.World']=true,['mod.class.Game']=true,['mod.class.GameState']=true,['mod.class.Zone']=true,['mod.class.Party']=true,['mod.class.Player']=true,['mod.class.PartyMember']=true,['mod.class.NPC']=true,['mod.class.Grid']=true,['mod.class.Object']=true,['engine.Map']=true,['engine.Level']=true,['engine.Calendar']=true}
    local function scan(v)
        if type(v)~='table' or seen[v] then return end
        seen[v]=true
        local mt=debug.getmetatable(v)
        local cname=rawget(v,'__CLASSNAME')
        if cname then
            if not supported_classes[cname] then error('unsupported class: '..tostring(cname)) end
            if mt and type(mt.__index)=='table' then anchor(mt.__index,'class:'..cname) end
        end
        for k,x in next,v do scan(k); scan(x) end
    end
    scan(state.game)
    scan(world)
    assert(state.visual_emit==state.map.particleEmitter,'untrusted particle emitter')
    anchor(state.visual_emit,'host:particleEmitter')
    anchor(state.Map,'class:engine.Map'); anchor(state.Map.call,'method:engine.Map.call')
    local effect=require('engine.interface.ActorTemporaryEffects').tempeffect_def.EFF_OFFBALANCE
    assert(effect and effect.resolveSource and effect.getName)
    anchor(effect.resolveSource,'effect:resolveSource'); anchor(effect.getName,'effect:getName')
    local g=state.game
    anchor(g.log,'host:log'); anchor(g.logNewest,'host:logNewest'); anchor(g.logRollback,'host:logRollback')
    anchor(g.playSound,'host:noop'); anchor(g.playSoundNear,'host:noop')
    anchor(debug.getmetatable(g.uiset.logdisplay).__call,'host:logdisplay')
    for i,actor in ipairs(state.allies) do
        anchor(actor.addEntityOrder,'ally:'..i..':addEntityOrder')
        anchor(actor.regenResourcesFast,'ally:'..i..':regenResourcesFast')
    end
    for i,actor in ipairs(state.enemies) do anchor(actor.regenResourcesFast,'enemy:'..i..':regenResourcesFast') end
    return byvalue,byname
end
local function uidstate(new)
    local init=require('engine.Entity').init
    for i=1,debug.getinfo(init,'u').nups do
        local name,old=debug.getupvalue(init,i)
        if name=='next_uid' then
            if new then debug.setupvalue(init,i,new) end
            return old
        end
    end
    error('missing uid counter')
end
function M.capture(state)
    if require('ai_input_task').active() then error('unsupported live AI input task') end
    if require('rule_events').has_pending() then error('unsupported pending rule events') end
    local g=state.game
    for _, actor in ipairs(state.allies) do if actor._mercenary_rescue then error('unsupported active rescue') end end
    if (g.on_tick_end and next(g.on_tick_end.fcts)) or (g.on_tick_end_custom and next(g.on_tick_end_custom.fcts)) or next(g.__coroutines) then error('unsupported live callbacks or coroutines') end
    if state.player.running_prev then
        assert(state.player.running_prev.levelstring==tostring(g.level), 'unclassified exploration level')
        assert(state.player.running_prev.dialog==nil, 'live exploration dialog')
    end
    local m=state.map
    if next(m.path_strings) then error('unsupported path string callbacks') end
    local special={[m.seens]=true,[m.infovs]=true,[m.has_seens]=true,[m.remembers]=true,[m.lites]=true,[m.attrs]=true}
    local omit={_map=true,_fovcache=true,_check_entities=true,_check_entities_store=true,path_strings_computed=true}
    local a=bindings(state)
    local graph=codec.encode({game=g,world=world,allies=state.allies,enemies=state.enemies,logs=state.logs,terrain_memory=state.terrain_memory,navigation_memory=state.navigation_memory,formal_differences=state.formal_differences,formal_map_attempts=state.formal_map_attempts},a,30000,{
        skip=function(t,k) return t==m and omit[k] end,
        skipmeta=function(t) return special[t] end,
    })
    local rs=rng.state_get(); rs.words=json.array(rs.words)
    return json.object({graph=graph,rng=json.object(rs),next_uid=uidstate()})
end
function M.restore(doc,fresh)
    local _,reverse=bindings(fresh)
    local state,tables=codec.decode(doc.graph,reverse)
    for _,fn in ipairs({state.game.log,state.game.logNewest,state.game.logRollback}) do
        local found=false
        for i=1,debug.getinfo(fn,'u').nups do
            local name=debug.getupvalue(fn,i)
            if name=='logs' then debug.setupvalue(fn,i,state.logs); found=true end
        end
        assert(found,'missing log upvalue')
    end
    game=state.game; world=state.world
    state.player=game.player; state.enemy=state.enemies[1]; state.map=game.level.map; state.Map=fresh.Map; state.visual_emit=fresh.visual_emit
    require('rescue').bind_restore(state)
    if state.player.running_prev then
        assert(type(state.player.running_prev.levelstring)=='string' and state.player.running_prev.dialog==nil, 'invalid exploration history')
        state.player.running_prev.levelstring=tostring(game.level)
    end
    assert(type(doc.next_uid)=='number' and doc.next_uid==math.floor(doc.next_uid) and doc.next_uid>0 and doc.next_uid<=9007199254740991,'invalid uid counter')
    __uids=setmetatable({},{__mode='v'})
    for _,v in ipairs(tables) do
        if rawget(v,'uid') and rawget(v,'__CLASSNAME') then
            assert(type(v.uid)=='number' and v.uid==math.floor(v.uid) and v.uid>0 and v.uid<doc.next_uid,'invalid uid')
            assert(not __uids[v.uid],'duplicate uid')
            __uids[v.uid]=v
        end
    end
    uidstate(doc.next_uid)
    if next(state.map.path_strings) then error('unsupported path string callbacks') end
    assert(state.map.particleEmitter==state.visual_emit,'particle binding mismatch')
    state.map:loaded()
    rng.state_set(doc.rng)
    return state
end
return M
