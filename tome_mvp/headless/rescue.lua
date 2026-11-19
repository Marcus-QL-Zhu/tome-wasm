-- Native party incapacitation and rescue.  Installed once per Lua VM.
local M = {}
local EFFECT = 'EFF_MERCENARY_DOWN'
local TALENT = 'T_MERCENARY_RESCUE'
local installed = false
local active_state
local function is_core(actor)
    if not actor or not active_state then return false end
    for _, member in ipairs(active_state.allies) do if member==actor then return true end end
    return false
end
local down
local down_listener
function M.set_down_listener(fn) down_listener=fn end
local removing = setmetatable({}, {__mode='k'})

function M.is_down(a)
    return a and a.tmp and a.tmp[EFFECT] ~= nil or false
end

local function finishing_fearscape(actor,id)
    return id=='T_DEMON_PLANE' and game.zone and game.zone.is_demon_plane and actor:isTalentActive(id)
end

-- Trusted post-defeat withdrawal only; never used by player rescue.
function M.withdraw_leader(a)
    assert(a and M.is_down(a) and not a.dead, 'down leader required')
    removing[a]=true
    local ok,err=pcall(function() a:removeEffect(EFFECT,true,true) end)
    removing[a]=nil
    if not ok then error(err) end
    assert(not M.is_down(a),'leader still down')
    a.life=1; a.changed=true
end

local function invalid(a)
    return not a or a.dead or M.is_down(a) or a:attr('stunned') or a:attr('paralyzed')
        or a:attr('sleep') or a:attr('dazed') or a:attr('confused') or a:attr('never_move')
        or a:attr('stoned') or a:attr('encased') or a:attr('encased_in_ice')
end

function M.can_rescue(caster, target)
    if not caster or not target or caster == target then return false, 'invalid_target' end
    if not game.party:hasMember(caster) or not game.party:hasMember(target) then return false, 'not_party' end
    if not game.level:hasEntity(caster) or not game.level:hasEntity(target) then return false, 'not_on_level' end
    if invalid(caster) then return false, 'incapacitated' end
    if not M.is_down(target) then return false, 'target_not_down' end
    if not caster.x or not target.x or math.max(math.abs(caster.x-target.x), math.abs(caster.y-target.y)) ~= 1 then
        return false, 'not_adjacent'
    end
    local Map=require 'engine.Map'
    if game.level.map(caster.x,caster.y,Map.ACTOR)~=caster or game.level.map(target.x,target.y,Map.ACTOR)~=target then return false, 'not_on_level' end
    if not caster:canProject({type='hit', range=1.5},target.x,target.y) then return false, 'blocked_target' end
    return true
end

local function valid_session(a)
    local r = a._mercenary_rescue
    if not r then return false, 'not_rescuing' end
    local ok, why = M.can_rescue(a, r.target)
    if not ok then return false, why end
    if a.x ~= r.x or a.y ~= r.y or r.target.x ~= r.tx or r.target.y ~= r.ty then return false, 'moved' end
    return true
end

function M.progress(a)
    local r = a and a._mercenary_rescue
    if not r then return nil end
    return {target_uid=r.target.uid, completed=math.min(20, (a.resting and a.resting.cnt or 1)-1), total=20}
end

function M.cancel(a)
    if not a or not a._mercenary_rescue then return false, 'not_rescuing' end
    if a.resting then a:restStop('interrupted') else a._mercenary_rescue=nil end
    return true
end

local function start_rest(a, target)
    local ok, why = M.can_rescue(a, target)
    if not ok then return false, why end
    if a ~= game.player or not a.restInit then return false, 'not_controlled' end
    if a.resting or a._mercenary_rescue then return false, 'busy' end
    if not a:enoughEnergy() then return false, 'insufficient_energy' end
    a._mercenary_rescue={target=target,x=a.x,y=a.y,tx=target.x,ty=target.y}
    local Dialog=require 'engine.ui.Dialog'
    local popup=Dialog.simplePopup
    Dialog.simplePopup=function(_, title, message, callback)
        assert(title=='Rescuing...' and message=='You are rescuing, press Enter to stop.' and type(callback)=='function', 'unclassified rescue dialog')
        return {__headless_rescue_progress=true}
    end
    local ok, err=xpcall(function() a:restInit(20, 'rescuing', 'rescued', function(cnt, max)
        local r=a._mercenary_rescue
        if r and r.completing and cnt > max and valid_session(a) then
            removing[r.target]=true
            r.target:removeEffect(EFFECT, true, true)
            removing[r.target]=nil
            r.target.life=r.target.max_life * 0.2
            r.target.changed=true
        end
        a._mercenary_rescue=nil
    end) end,debug.traceback)
    Dialog.simplePopup=popup
    if not ok then a._mercenary_rescue=nil; error(err) end
    if not a.resting then a._mercenary_rescue=nil; return false, 'interrupted' end
    -- Refit's rest counter completes at max+1.  Count the initial native
    -- energy use as turn one without charging an additional 21st turn.
    a.resting.cnt=a.resting.cnt+1
    return true
end

function M.start(a, target)
    local ok, why=M.can_rescue(a,target)
    if not ok then return false,why end
    if a ~= game.player then return false,'not_controlled' end
    if not a:knowTalent(TALENT) then return false,'not_learned' end
    if a.resting or a._mercenary_rescue then return false,'busy' end
    if not a:enoughEnergy() then return false,'insufficient_energy' end
    if not a:useTalent(TALENT,nil,nil,nil,target,false,true) then return false,'talent_declined' end
    return true
end

function M.step(a)
    if not a or not a._mercenary_rescue or not a.resting then return false, 'not_rescuing' end
    local ok, why=valid_session(a)
    if not ok then M.cancel(a); return false, why end
    if not a:enoughEnergy() then return false, 'insufficient_energy' end
    if a.resting.cnt > a.resting.rest_turns then a._mercenary_rescue.completing=true end
    a:restStep()
    return true
end

local function clear_targets(target)
    for _, actor in pairs(game.level.entities) do
        if actor.ai_target and actor.ai_target.actor == target then
            if actor.setTarget then actor:setTarget(nil) else actor.ai_target.actor=nil end
        end
        if actor.resetCanSeeCache then actor:resetCanSeeCache() end
    end
end

down=function(a,source)
    if a.resting and a.restStop then a:restStop('incapacitated') end
    a.life=0
    if not M.is_down(a) then
        a:setEffect(EFFECT, 1000000000, {}, true)
        a._mercenary_down_serial=(a._mercenary_down_serial or 0)+1
        local seen={}
        while type(source)=='table' and type(source.summoner)=='table' and not seen[source] do
            seen[source]=true
            source=source.summoner
        end
        a._mercenary_down_source_uid=nil
        if type(source)=='table' and source~=a and source.uid and source.reactionToward
           and source:reactionToward(a)<0 then
            a._mercenary_down_source_uid=source.uid
        end
        if down_listener then down_listener(a) end
    end
    clear_targets(a)
    a.changed=true
    return false
end

function M.install()
    if installed then return end
    installed=true
    local effects=require 'engine.interface.ActorTemporaryEffects'
    effects:newEffect{name='MERCENARY_DOWN', desc='\230\153\149\229\128\146', type='other', subtype={incapacitated=true}, status='detrimental',
        decrease=0, no_remove=true, parameters={}, long_desc=function() return 'Unconscious until rescued.' end,
        -- Tell native restCheck the same fact enforced by heal/regenLife below.
        -- Native effect cleanup removes this value after rescue or withdrawal.
        activate=function(self,eff) self:effectTemporaryValue(eff,'no_life_regen',1) end}
    local talents=require 'engine.interface.ActorTalents'
    talents:newTalentType{name='Mercenary rescue',type='misc/mercenary-rescue',description='Permanent party rescue'}
    talents:newTalent{name='Mercenary Rescue',short_name='MERCENARY_RESCUE',type={'misc/mercenary-rescue',1},
        points=1, no_unlearn_last=true, no_energy=true, range=1.5,
        target={type='hit',range=1.5}, info='Rescue an adjacent unconscious party member over twenty turns.',
        callbackPriorities={callbackOnDie=1000000},
        callbackOnDie=function(self,t,value,source)
            if is_core(self) and self.life <= self.die_at then down(self,source); return true end
        end,
        action=function(self,t)
            local x,y,target=self:getTarget(self:getTalentTarget(t))
            if not target and x and y then target=game.level.map(x,y,require('engine.Map').ACTOR) end
            local ok=start_rest(self,target)
            return ok
        end}
    local classes={require 'mod.class.Actor', require 'mod.class.NPC', require 'mod.class.PartyMember', require 'mod.class.Player'}
    for _, cls in ipairs(classes) do
        local die, hit, heal, regen, move, act, see, unlearn, remove=cls.die,cls.takeHit,cls.heal,cls.regenLife,cls.move,cls.act,cls.canSee,cls.unlearnTalent,cls.removeEffect
        local use, force, attack, setTarget, setEffect=cls.useTalent,cls.forceUseTalent,cls.attackTarget,cls.setTarget,cls.setEffect
        if die then cls.die=function(self, ...)
            if is_core(self) then return down(self,select(1,...)) end
            if not self._dm_wipeout_spoils then return die(self, ...) end
            local level,x,y=game.level,self.x,self.y
            local result=die(self,...)
            if self.dead and self._dm_wipeout_spoils then
                require('campaign_wipeout').drop_spoils(self,level.map,x,y)
            end
            return result
        end end
        if hit then cls.takeHit=function(self, value, ...)
            if M.is_down(self) then self.life=0; return false, 0 end
            local dead, dealt=hit(self,value,...)
            if self._mercenary_rescue and dealt and dealt > 0 then M.cancel(self) end
            return dead, dealt
        end end
        if heal then cls.heal=function(self, ...) if M.is_down(self) then self.life=0; return 0 end return heal(self, ...) end end
        if regen then cls.regenLife=function(self, ...) if M.is_down(self) then self.life=0; return end return regen(self, ...) end end
        if move then cls.move=function(self,x,y,...)
            if M.is_down(self) and (x~=self.x or y~=self.y) then
                local origin=active_state and active_state._plane_origin
                if not origin or game.level.map~=origin.map or select(1,...)~=true then return false end
            end
            local ox,oy=self.x,self.y
            local result=move(self,x,y,...)
            if self._mercenary_rescue and (self.x~=ox or self.y~=oy) then M.cancel(self) end
            return result
        end end
        if act then cls.act=function(self, ...) if M.is_down(self) then self.life=0; self:useEnergy(); return end return act(self, ...) end end
        if see then cls.canSee=function(self, actor, ...) if M.is_down(actor) and not game.party:hasMember(self) then return false,0 end return see(self,actor,...) end end
        if unlearn then cls.unlearnTalent=function(self,id,...) if is_core(self) and id==TALENT then return false,'permanent_talent' end return unlearn(self,id,...) end end
        if remove then cls.removeEffect=function(self,id,...) if id==EFFECT and not removing[self] then return false end return remove(self,id,...) end end
        if use then cls.useTalent=function(self,id,...)
            if M.is_down(self) and not finishing_fearscape(self,type(id)=='table' and id.id or id) then return false end
            return use(self,id,...)
        end end
        if force then cls.forceUseTalent=function(self,id,...)
            if M.is_down(self) and not finishing_fearscape(self,type(id)=='table' and id.id or id) then return false end
            return force(self,id,...)
        end end
        if attack then cls.attackTarget=function(self,...) if M.is_down(self) then return false end return attack(self,...) end end
        if setTarget then cls.setTarget=function(self,target,...) if M.is_down(target) and not game.party:hasMember(self) then target=nil end return setTarget(self,target,...) end end
        if setEffect then cls.setEffect=function(self,...)
            local result=setEffect(self,...)
            if self._mercenary_rescue and invalid(self) then M.cancel(self) end
            return result
        end end
    end
    local Player=require 'mod.class.Player'
    local restCheck=Player.restCheck
    Player.restCheck=function(self, ...)
        if self._mercenary_rescue then return valid_session(self) end
        return restCheck(self,...)
    end
end

local function install_target_filter()
    local ai=require 'mod.class.interface.ActorAI'
    if not ai._mercenary_target_filter then
        for _,name in ipairs({'target_simple','target_closest'}) do
            local original=assert(ai.ai_def[name],'missing native target selector')
            ai.ai_def[name]=function(actor,...)
                if game.party and game.party:hasMember(actor) then return original(actor,...) end
                local args={n=select('#',...),...};local fov=actor.fov;local prior=fov and fov.actors_dist
                if prior then
                    local filtered={};for _,target in ipairs(prior) do if not M.is_down(target) then filtered[#filtered+1]=target end end
                    fov.actors_dist=filtered
                end
                local result
                local ok,err=xpcall(function()
                    if actor.ai_target and M.is_down(actor.ai_target.actor) then actor:setTarget(nil) end
                    result={original(actor,unpack(args,1,args.n))}
                end,debug.traceback)
                if prior then fov.actors_dist=prior end
                if not ok then error(err) end
                if result[1] and actor.ai_target and result[1]~=actor.ai_target.actor then result[1]=actor.ai_target.actor end
                return unpack(result)
            end
        end
        ai._mercenary_target_filter=true
    end
end
function M.bind_party(state)
    active_state=state
    install_target_filter()
    for _,a in ipairs(state.allies) do
        a._mercenary_party=true
        if not a:knowTalent(TALENT) then assert(a:learnTalent(TALENT,true,1,{no_unlearn=true})) end
    end
end

function M.bind_restore(state)
    active_state=state
    install_target_filter()
    for _, a in ipairs(state.allies) do
        assert(a._mercenary_party and a:knowTalent(TALENT), 'missing permanent rescue talent')
        assert(not a._mercenary_rescue, 'unsupported active rescue')
    end
end
return M
