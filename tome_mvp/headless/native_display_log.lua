-- Native delayed display batches use pairs() over tables keyed by entities.
-- A process address can change their display order without changing any action.
local M={}
local installed=false

local function ordered_display(flush,queue)
    return function(game)
        local ui=game.uiset
        if not ui or not ui.logdisplay or not next(game[queue]) then return flush(game) end
        local sink=ui.logdisplay
        local records={}
        ui.logdisplay=setmetatable({}, {__index=sink,__call=function(_, ...)
            sink(...)
            if debug.getinfo(2,'f').func==flush then
                local _,record=game.logNewest()
                records[#records+1]=record
            end
        end})
        -- Run all original formatting, visibility, RNG calls, and death callbacks.
        local ok,err=xpcall(function() flush(game) end,debug.traceback)
        ui.logdisplay=sink
        if not ok then error(err,0) end
        if #records<2 then return end
        local lines={}
        for i,record in ipairs(records) do lines[i]=record.str end
        table.sort(lines)
        for i,record in ipairs(records) do record.str=lines[i] end
    end
end

function M.install(Game)
    if installed then return end
    Game.displayDelayedLogDamage=ordered_display(Game.displayDelayedLogDamage,'delayed_log_damage')
    Game.displayDelayedLogMessages=ordered_display(Game.displayDelayedLogMessages,'delayed_log_messages')
    installed=true
end

return M
