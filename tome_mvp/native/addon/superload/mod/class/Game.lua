local _M = loadPrevious(...)
local base_new_game = _M.newGame
local base_run = _M.run
local base_display = _M.display
local base_tick = _M.tick
require "Json2"
local host={busy=false,active=nil}
function _M:newGame()
    local seed=self.bridge_seed
    if not seed then
        local seed_file=assert(fs.open("/settings/bridge-seed.cfg","r"))
        seed=assert(tonumber(seed_file:readLine())); seed_file:close()
    end
    rng.seed(seed)
    print("[ISOLATED BRIDGE] seed",seed)
    print("[ISOLATED BRIDGE] scene initialization begins")
    local Party = require "mod.class.Party"
    local Player = require "mod.class.Player"
    local GameState = require "mod.class.GameState"
    self.party = Party.new{}
    local p = Player.new{name=self.player_name, game_ender=true, faction="allied-kingdoms", max_life=100, life=100, sight=10, infravision=10, lite=2, stats={str=14,dex=13,con=12}, combat={dam=8,atk=5,apr=0,physspeed=1,dammod={str=1}}}
    self.party:addMember(p, {main=true,type="player",control="full",orders={target=true,anchor=true,behavior=true,leash=true,talents=true}})
    self.party:setPlayer(p)
    self.state = GameState.new{}
    p.can_change_level=true
    p.can_change_zone=true
    p.descriptor={world="Maj'Eyal",class="Warrior",subclass="Berserker",race="Human",subrace="Cornac",sex="Male",difficulty="Normal",permadeath="Roguelike"}
    local Birther=require "mod.dialogs.Birther"
    p.body=table.clone(Birther:getBirthDescriptor("base", "base").body, true)
    p:initBody()
    self:setupDifficulty(2)
    self:setupPermadeath(p)
    self:changeLevel(1,"isolated-bridge-probe+arena",{direct_switch=true})
    p:resolve(); p:resolve(nil,true)
    p.energy.value=self.energy_to_act
    require("engine.Map"):setViewerFaction(p.faction)
    p:resetToFull(); p:recomputeGlobalSpeed()
    self.bridge_actors={p}
    local function equip_named(a,name,slot)
        local template
        for _,o in ipairs(self.zone.object_list) do if o.name==name then template=o;break end end
        assert(template,"template missing: "..name)
        local item=self.zone:finishEntity(self.level,"object",template,-1000)
        item:identify(true)
        assert(a:wearObject(item,false,false),"equip failed: "..name)
        assert(a:getInven(slot)[1]==item,"slot missing: "..slot)
    end
    equip_named(p,"iron longsword","MAINHAND")
    local NPC=require "mod.class.NPC"
    local function add_actor(name, allied, x, y)
        local n=NPC.new{name=name,type="humanoid",subtype="human",display="p",color=colors.WHITE,
            faction=allied and "allied-kingdoms" or "enemies",level=1,rank=2,fixed_rating=true,
            max_life=allied and 90 or 65,life=allied and 90 or 65,life_rating=10,sight=10,infravision=10,lite=2,open_door=true,
            energy={value=0,mod=1},ai="improved_tactical",ai_state={ai_move="move_complex",talent_in=1},
            body={INVEN=10,MAINHAND=1,OFFHAND=1,BODY=1,QUIVER=1},stats={str=allied and 16 or 12,dex=allied and 15 or 11,con=12},
            combat={dam=8,atk=5,apr=0,physspeed=1,dammod={str=1}}}
        n:resolve(); n:resolve(nil,true)
        if allied then self.party:addMember(n,{control="no",type="ally",title=name,orders={target=true,anchor=true,leash=true}}) end
        self.zone:addEntity(self.level,n,"actor",x,y); n:resetToFull()
        if name=="Ally Two" then
            n:learnTalent(n.T_SHOOT,true,1)
            equip_named(n,"elm longbow","MAINHAND")
            equip_named(n,"quiver of elm arrows","QUIVER")
            local w,ammo=n:hasArcheryWeapon("bow")
            assert(w and ammo and ammo.combat.shots_left>0,"archery setup failed")
        else equip_named(n,"iron longsword","MAINHAND") end
        self.bridge_actors[#self.bridge_actors+1]=n
    end
    add_actor("Ally One",true,9,10); add_actor("Ally Two",true,9,11)
    add_actor("Enemy One",false,12,10); add_actor("Enemy Two",false,15,10)
    add_actor("Enemy Three",false,16,12); add_actor("Enemy Four",false,17,14); add_actor("Enemy Five",false,18,16)
    self.paused=true
    print("[ISOLATED BRIDGE] scene initialization complete")
end

function _M:run(...)
    local result=base_run(self,...)
    self.bridge_ready=true
    self.bridge_generation=self.bridge_generation or 1
    if not host.busy then host.active=self end
    self.player:doFOV()
    return result
end
local function danger(self)
    for i=1,3 do
        local a=self.bridge_actors[i]
        if not a or a.dead or (a.life and a.max_life and a.life<=a.max_life*0.25) then return true end
    end
    return false
end
local function snapshot(self)
    self.player:doFOV()
    local map=self.level.map
    local Map=require "engine.Map"
    local rows={}
    for y=0,63 do
        local row={}
        for x=0,63 do
            if map.has_seens(x,y) then local terrain=map(x,y,Map.TERRAIN); row[#row+1]=(terrain and terrain.display) or "."
            else row[#row+1]=" " end
        end
        rows[#rows+1]=table.concat(row)
    end
    local party,enemies={},{}
    for i,a in ipairs(self.bridge_actors) do
        if (i<=3) or (not a.dead and a.x and a.y) then
            local weapon=a:getInven("MAINHAND")[1]
            local ammo=a:getInven("QUIVER")[1]
            local v={id=tostring(i),name=a.name,x=a.x,y=a.y,hp=a.life,max_hp=a.max_life,dead=not not a.dead,equipment=weapon and weapon.name or "unarmed",ammo=ammo and ammo.combat and ammo.combat.shots_left or nil}
            if i<=3 then party[#party+1]=v
            elseif map.seens(a.x,a.y) and self.player:canSee(a) then enemies[#enemies+1]=v end
        end
    end
    for _,a in ipairs(party) do if a.x and a.y and not a.dead then local row=rows[a.y+1]; if row then rows[a.y+1]=row:sub(1,a.x).."@"..row:sub(a.x+2) end end end
    for _,a in ipairs(enemies) do local row=rows[a.y+1]; if row then rows[a.y+1]=row:sub(1,a.x).."e"..row:sub(a.x+2) end end
    return {generation=self.bridge_generation or 1,turn=self.turn or 0,map={width=64,height=64,rows=rows},party=party,enemies=enemies,online=true,status=danger(self) and "danger" or "paused",pause_reason=danger(self) and "ally_hp_at_or_below_25_percent_or_dead" or nil,
        capabilities={move=true,wait=true,melee=true,ranged=false,ai_step=not danger(self),pause=true,new_game=true,save=false,load=false}}
end
local function respond(self,seq,status)
    local ok,result=pcall(snapshot,self)
    if not ok then self:saveSettings("bridge-response",seq.."|error|"..tostring(result).."|END\n"); return end
    self:saveSettings("bridge-response",seq.."|"..status.."|"..json.encode(result).."|END\n")
end
function _M:tick(...)
    if host.busy or (host.active and host.active~=self) or self.bridge_failed then return true end
    local r=base_tick(self,...)
    if self.bridge_pending then
        self.bridge_pending.ticks=self.bridge_pending.ticks+1
        if self.bridge_pending.ticks>500 then
            self.paused=true
            self.bridge_failed=true
            respond(self,self.bridge_pending.seq,"tick_limit")
            self.bridge_pending=nil
        end
    end
    if self.bridge_pending and not (self.paused and self.player:enoughEnergy()) then
        core.game.requestNextTick()
        return false
    end
    return r
end
function _M:display(...)
    if host.busy or (host.active and host.active~=self) then return end
    if self.bridge_pending and self.bridge_pending.ticks>0 and self.paused and self.player:enoughEnergy() then
        respond(self,self.bridge_pending.seq,"ok")
        self.bridge_pending=nil
    end
    local f=fs.open("/settings/bridge-command.cfg","r")
    if f then
        local line=f:readLine(); f:close()
        local seq,command,arg1,arg2=(line or ""):match("^(%d+)|([a-z_]+)|([^|]*)|([^|]*)$")
        if self.bridge_ready and not self.bridge_pending and seq and tonumber(seq)>(self.bridge_last_seq or 0) then
            self.bridge_last_seq=tonumber(seq)
            if command=="new_game" then
                local seed=tonumber(arg1)
                if not seed or seed<0 or seed>2147483647 or seed~=math.floor(seed) then respond(self,seq,"rejected")
                else self.bridge_reset={seed=seed,seq=seq} end
            elseif command=="observe" or command=="pause" then
                respond(self,seq,"ok")
            elseif command=="ai_step" and danger(self) then
                respond(self,seq,"blocked_danger")
            elseif command=="wait" or command=="move" or command=="attack" or command=="ai_step" then
                local before=self.player.energy.value
                if command=="wait" then self.player:waitTurn()
                elseif command=="attack" then
                    local target=self.bridge_actors[tonumber(arg1) or 0]
                    if target and not target.dead and target.x and self.level.map.seens(target.x,target.y)
                        and self.player:canSee(target) and math.max(math.abs(target.x-self.player.x),math.abs(target.y-self.player.y))==1
                        and self.player:reactionToward(target)<0 then self.player:move(target.x,target.y) end
                elseif command=="ai_step" then
                    local p=self.player
                    local old_set,old_get=rawget(p,"setTarget"),rawget(p,"getTarget")
                    p.setTarget=require("mod.class.interface.ActorAI").setTarget
                    p.getTarget=require("engine.interface.ActorAI").getTarget
                    p:doFOV(); p.energy.used=false
                    local ok,err=pcall(function() p:runAI("improved_tactical") end)
                    p.setTarget=old_set; p.getTarget=old_get
                    if not ok then print("[ISOLATED BRIDGE] ai error",err) end
                else
                    local dx,dy=tonumber(arg1),tonumber(arg2)
                    if dx and dy and math.abs(dx)<=1 and math.abs(dy)<=1 and (dx~=0 or dy~=0) then
                        self.player:move(self.player.x+dx,self.player.y+dy)
                    end
                end
                if self.player.energy.value<before then
                    self.bridge_pending={seq=seq,ticks=0}
                    self:saveSettings("bridge-trace", "energy="..before.."->"..self.player.energy.value.." paused="..tostring(self.paused).." player="..tostring(self.player.player).."\n")
                    core.game.requestNextTick()
                else respond(self,seq,"rejected") end
            else respond(self,seq,"unsupported") end
        end
    end
    local result=base_display(self,...)
    if self.bridge_reset then
        local request=self.bridge_reset
        self.bridge_reset=nil
        self.bridge_ready=false
        host.busy=true
        local next_game
        local ok,err=pcall(function()
            assert(not savefile_pipe.saving and #savefile_pipe.pipe==0 and not next(savefile_pipe.waiton or {}),"save in progress")
            local old_world=world
            local old_entities={}
            for _,e in ipairs(self.level.e_array) do old_entities[e]=true end
            self:onTickEndCancelAll()
            require("mod.class.Zone"):removeLastPersistZone("isolated-bridge-probe+arena")
            self.level.map:close()
            core.particles.flushLast()
            _G.game=false
            next_game=_M.new()
            next_game.bridge_generation=(self.bridge_generation or 1)+1
            next_game.bridge_last_seq=tonumber(request.seq)
            next_game.bridge_seed=request.seed
            next_game:setPlayerName("bridge")
            next_game.save_name="bridge-"..next_game.bridge_generation
            _G.game=next_game
            _G.world=require("mod.class.World").new()
            world:run()
            next_game:prerun(); next_game:run()
            next_game.key:setupRebootKeys()
            next_game.key:setCurrent(); next_game.mouse:setCurrent()
            assert(next_game~=self and world~=old_world and next_game.level~=self.level and next_game.level.map~=self.level.map and next_game.zone~=self.zone and next_game.party~=self.party and next_game.state~=self.state,"old scene reference retained")
            for _,e in ipairs(next_game.level.e_array) do assert(not old_entities[e],"old level entity reused") end
            if self._timers_cb then assert(next_game._timers_cb~=self._timers_cb,"old timer registry retained") end
            local old_uids={}
            for _,a in ipairs(self.bridge_actors) do old_uids[a.uid]=true end
            for _,a in ipairs(next_game.bridge_actors) do
                assert(not old_uids[a.uid],"old actor reused")
            end
            for uid in pairs(old_uids) do
                assert(not next_game.level.entities[uid] and not next_game.entities[uid],"old actor still registered")
            end
            local Map=require "engine.Map"
            local actor_count,projectile_count=0,0
            for y=0,63 do for x=0,63 do
                local actor=next_game.level.map(x,y,Map.ACTOR)
                if actor then actor_count=actor_count+1; assert(not old_uids[actor.uid],"old actor still on map") end
                if next_game.level.map(x,y,Map.PROJECTILE) then projectile_count=projectile_count+1 end
            end end
            assert(actor_count==8 and projectile_count==0,"nonempty or invalid fresh map")
            assert(next_game.turn==0 and not next_game.level.last_iteration and next_game.paused and next_game.player:enoughEnergy(),"fresh scheduler not clear")
            local timer_count=0
            for _ in pairs(next_game._timers_cb or {}) do timer_count=timer_count+1 end
            next_game:saveSettings("bridge-reset-audit",json.encode({generation=next_game.bridge_generation,actors=actor_count,projectiles=projectile_count,timers=timer_count,old_actor_registrations=0,turn=next_game.turn}).."\n")
        end)
        if not ok then
            (next_game or self).bridge_failed=true
            (next_game or self):saveSettings("bridge-response",request.seq.."|error|reset failed|END\n")
            print("[ISOLATED BRIDGE] reset failed",err)
        else
            host.active=next_game
            host.busy=false
            respond(next_game,request.seq,"ok")
        end
    end
    return result
end
return _M
