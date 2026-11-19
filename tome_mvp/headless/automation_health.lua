-- Decision-boundary health episodes. No combat rules or damage are computed here.
local M={}
function M.new(rescue)
    local confirmed, previous, alert, published={},{},nil,nil
    local function reset() confirmed={}; previous={}; alert=nil; published=nil end
    local function acknowledge()
        if alert and alert~=published then return false end
        if alert then
            for _,event in ipairs(alert) do if event.kind=='threshold' then confirmed[event.key]=true end end
            alert=nil; published=nil
        end
        return true
    end
    local function check(state)
        local enemies=0
        for _,foe in ipairs(state.enemies) do if not foe.dead and state.visible[foe.uid] then enemies=enemies+1 end end
        local active, events={}, {}
        for _,actor in ipairs(require('units').party(state)) do
            if not actor.dead and not rescue.is_down(actor) and actor.max_life and actor.max_life>0 then
                local id=tostring(actor.uid); local hp=actor.life; local max=actor.max_life
                local lines={{20,0},{40,1},{50,3},{60,5},{70,7}}
                for _,line in ipairs(lines) do
                    local percent,minimum=line[1],line[2]
                    if enemies>=minimum and hp<max*percent/100 then
                        local key=id..':'..percent; active[key]=true
                        if not confirmed[key] then events[#events+1]={kind='threshold',key=key,actor_id=actor.uid,percent=percent,hp=hp,max_hp=max} end
                    end
                end
                local old=previous[id]
                if old and old-hp>max*0.25 then events[#events+1]={kind='damage',actor_id=actor.uid,hp=hp,max_hp=max,loss=old-hp} end
                previous[id]=hp
            end
        end
        for key in pairs(confirmed) do if not active[key] then confirmed[key]=nil end end
        if #events>0 then alert=events; return true end
        return false
    end
    local function manual(state)
        local enemies=0
        for _,foe in ipairs(state.enemies) do if not foe.dead and state.visible[foe.uid] then enemies=enemies+1 end end
        local active={}
        for _,actor in ipairs(require('units').party(state)) do
            if not actor.dead and not rescue.is_down(actor) and actor.max_life and actor.max_life>0 then
                local id=tostring(actor.uid)
                for _,line in ipairs({{20,0},{40,1},{50,3},{60,5},{70,7}}) do
                    if enemies>=line[2] and actor.life<actor.max_life*line[1]/100 then active[id..':'..line[1]]=true end
                end
                previous[id]=actor.life
            end
        end
        for key in pairs(confirmed) do if not active[key] then confirmed[key]=nil end end
        if alert then
            local kept={}
            for _,event in ipairs(alert) do if event.kind~='threshold' or active[event.key] then kept[#kept+1]=event end end
            if #kept~=#alert then alert=#kept>0 and kept or nil; published=nil end
        end
    end
    local function export_state()
        assert(not alert and not published,'active health alert cannot be saved')
        local c,p={},{}
        for k,v in pairs(confirmed) do c[k]=v end
        for k,v in pairs(previous) do p[k]=v end
        return {confirmed=c,previous=p}
    end
    local function import_state(data)
        assert(type(data)=='table' and type(data.confirmed)=='table' and type(data.previous)=='table','invalid health state')
        confirmed={};previous={};alert=nil;published=nil
        for k,v in pairs(data.confirmed) do assert(type(k)=='string' and v==true,'invalid health confirmation');confirmed[k]=v end
        for k,v in pairs(data.previous) do assert(type(k)=='string' and type(v)=='number' and v==v and math.abs(v)<math.huge,'invalid previous health');previous[k]=v end
    end
    return {reset=reset,acknowledge=acknowledge,check=check,manual=manual,alert=function() return alert end,publish=function() published=alert; return alert end,export_state=export_state,import_state=import_state}
end
return M
