-- Bounded shared observation: native sight FOV + native perception per ally.
-- Complex sensory effects remain conservative until individually verified.
local M={}
local rescue=require 'rescue'
local visuals=require 'visual_metadata'
local function perceived(actor,foe)
    if actor:attr('blind') then return false end
    if foe:attr('stealth') or foe:attr('invisible') then
        local entry=actor.can_see_cache and actor.can_see_cache[foe]
        entry=entry and entry['nil/nil']
        return entry and entry[1] and true or false
    end
    return actor:canSee(foe) and true or false
end
function M.refresh(state)
    require('units').refresh(state)
    local map,p=state.map,state.player
    local w=map.w
    state.visible={}; state.player_visible={}; state.shared_seen={}
    for y=0,map.h-1 do for x=0,w-1 do
        if not rescue.is_down(p) and map.seens(x,y) then state.shared_seen[x+y*w]=true end
    end end
    for _,foe in ipairs(state.observed_actors) do
        local v=not rescue.is_down(p) and not foe.dead and map.seens(foe.x,foe.y) and perceived(p,foe) and true or false
        state.player_visible[foe.uid]=v; state.visible[foe.uid]=v
    end
    -- Mirror the ordinary optical part of Player.playerFOV: map light and
    -- each real emitter's unobstructed light reach. Keep this separate from
    -- map.seens and actor FOV stores, which belong to the controlled actor.
    local light={}
    for _,emitter in pairs(state.game.level.entities) do
        local radius=math.max(emitter.lite or 0,emitter.radiance_aura or 0)
        if radius>0 and emitter.x and emitter.y and emitter.computeFOV then
            emitter:computeFOV(radius,'block_sight',function(x,y)
                local index=x+y*w
                if light[index] and light[index]~=emitter then light[index]=true
                else light[index]=emitter end
            end,true,true,false)
        end
    end
    for _,ally in ipairs(require('units').party(state)) do
        if ally~=p and not ally.dead and not rescue.is_down(ally) and ally.x and not ally:attr('blind') then
            local seen={}
            ally:computeFOV(ally.sight or 10,'block_sight',function(x,y)
                local index=x+y*w
                local source=light[index]
                local lit=source and (source~=ally or (ally.lite or 0)>0)
                if map.lites(x,y) or lit or (x==ally.x and y==ally.y) then
                    seen[index]=true; state.shared_seen[index]=true
                end
            end,true,true,false)
            for _,foe in ipairs(state.observed_actors) do
                if not foe.dead and seen[foe.x+foe.y*w] and perceived(ally,foe) then state.visible[foe.uid]=true end
            end
        end
    end
    state.terrain_memory=state.terrain_memory or {}
    for index in pairs(state.shared_seen) do
        local x=index%w; local y=math.floor(index/w)
        state.terrain_memory[index]=visuals.terrain(map(x,y,state.Map.TERRAIN))
    end
end
return M
