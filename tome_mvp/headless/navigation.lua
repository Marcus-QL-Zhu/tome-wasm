-- Native A* sees only the last authorized terrain observations.
local Astar=require 'engine.Astar'
local M={}
function M.capture(state,p)
    local map=state.map
    state.navigation_memory=state.navigation_memory or {}
    for index in pairs(state.shared_seen) do
        local x,y=index%map.w,math.floor(index/map.w)
        local blocked=map:checkEntity(x,y,state.Map.TERRAIN,'block_move',p,nil,true) and true or false
        local grid=map(x,y,state.Map.TERRAIN)
        local trap=map(x,y,state.Map.TRAP)
        local unsafe=trap and trap:knownBy(p) and trap:canTrigger(x,y,p,true) and true or false
        if grid and grid.door_opened and (grid.door_player_check or grid.door_player_stop) then unsafe=true end
        local air=map:checkEntity(x,y,state.Map.TERRAIN,'air_level')
        local condition=map:checkEntity(x,y,state.Map.TERRAIN,'air_condition')
        if air and not p:attr('no_breath') and (not condition or not p.can_breath or not p.can_breath[condition] or p.can_breath[condition]<=0) then unsafe=true end
        state.navigation_memory[index]={blocked=blocked,unsafe=unsafe}
    end
end
function M.path(state,p,x,y)
    local map=state.map
    local function remembered(a,b)
        return map:isBound(a,b) and state.navigation_memory and state.navigation_memory[a+b*map.w]
    end
    if not remembered(x,y) then return nil end
    local facade={w=map.w,h=map.h,_fovcache={path_caches={}}}
    function facade:isBound(a,b) return map:isBound(a,b) end
    function facade:checkEntity(a,b,layer,key,actor,...)
        local entry=remembered(a,b)
        return not entry or entry.blocked
    end
    facade.has_seens=function(a,b) return remembered(a,b) and true or false end
    local function permitted(a,b)
        local entry=remembered(a,b)
        return entry and not entry.unsafe or false
    end
    return Astar.new(facade,p):calc(p.x,p.y,x,y,true,nil,permitted)
end
return M
