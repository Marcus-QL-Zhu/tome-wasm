local function prepare(seed, fixture, restoring)
    require('rule_events').begin_scene()
    core.display.getModesList=function() return {} end
    core.display.FBOActive=function() return false end
    package.loaded["engine.Module"]=setmetatable({}, {__index=function(_,k) error("unavailable desktop module operation "..k) end})
    core.fov.set_algorithm("large_ass")
    core.fov.set_permissiveness(0.01)
    core.fov.set_actor_vision_size(1)
    core.fov.set_vision_shape("circle")
    local Map=require "engine.Map"
    local Level=require "engine.Level"
    local Game=require "mod.class.Game"
    require('localization').install_game(Game)
    require('native_inputs').install(Game)
    local Zone=require "mod.class.Zone"
    local Grid=require "mod.class.Grid"
    local Player=require "mod.class.Player"
    local NPC=require "mod.class.NPC"
    local rescue=require 'rescue'
    rescue.install()
    local Party=require "mod.class.Party"
    local State=require "mod.class.GameState"
    local noop=function() end
    local layer={setObscure=noop,setShown=noop,setupGridLines=noop,setDefaultShader=noop,zCallback=noop,setImportant=noop,setGrid=noop,setLite=noop,setSeen=noop,setRemember=noop,setScroll=noop,cleanSeen=noop}
    core.map={newMap=function() return layer end}
    core.key={modState=function(k) assert(k=='ctrl'); return false end}
    core.game.checkError=function() return nil end
    core.game.requestNextTick=function() end
    savefile_pipe={saving=false}
    local viewport_size=(fixture=='formal' and tonumber(TOME_SCENE_SIZE)) or 64
    Map.viewport={width=viewport_size,height=viewport_size,mwidth=viewport_size,mheight=viewport_size}
    Map.tile_w,Map.tile_h=1,1
    Map.zoom,Map.display_x,Map.display_y=1,0,0
    Map.particleEmitter=function(_,x,y,radius,kind)
        assert(kind=="melee_attack","unclassified particle emitter "..tostring(kind))
    end
    Map.updateMapDisplay=function(self,x,y)
        self.__rule_visibility_revision=(self.__rule_visibility_revision or 0)+1
        local g=self(x,y,Map.TERRAIN)
        if not g then return end
        for _,ps in ipairs(self.path_strings) do
            self._fovcache.path_caches[ps]:set(x,y,g:check("block_move",x,y,self.path_strings_computed[ps] or ps,false,true))
        end
    end
    rng.seed(seed)
    game=Game.castAs({
        real_starttime=os.time(),w=1280,h=720,energy_to_act=1000,energy_per_tick=100,can_pause=true,turn=0,paused=true,
        entities=setmetatable({},{__mode="v"}),__coroutines={},delayed_log_messages={},delayed_log_damage={},
        dialogs={},uniques={},player_name="Probe",tiles_attachements={},tiles_facing={},
        uiset={hotkeys_display={},hotkeys_display_icons={tiles={__headless_dialog=true}}},target={target={}},flyers={add=noop},
        log=function(...) print("EVENT",...) end,playSoundNear=noop,playSound=noop,
    })
    local logs={}
    game.log=function(fmt,...)
        -- Use the same tstring formatting as native LogDisplay:call.
        -- The Lua 5.1 string formatter needs native tstring arguments flattened.
        local args,n={...},select('#',...)
        for i=1,n do if type(args[i])=='table' and args[i].is_tstring then args[i]=args[i]:toString() end end
        local t={str=require('localization').format(fmt,unpack(args,1,n))}
        logs[#logs+1]=t; if #logs>500 then table.remove(logs,1) end
    end
    game.logNewest=function() local l=logs[#logs]; if l then return l.str,l end end
    game.logRollback=function(l) while #logs>0 and logs[#logs]~=l do logs[#logs]=nil end end
    if TOME_SCENE_SIZE then game.__mod_info=require('native_module_info') end
    -- Native quest state remains intact. Noninteractive desktop notifications
    -- use the original "no popup" setting and enter the browser battle log.
    config.settings.tome.quest_popup=false
    game.bignews={
        saySimple=function(_,duration,text)assert(type(text)=='string','unsupported news message');game.log('%s',text)end,
        say=function(_,duration,fmt,...)assert(type(fmt)=='string','unsupported news message');game.log(fmt,...)end,
    }
    game.uiset.logdisplay=setmetatable({getNewestLine=game.logNewest},{__call=function(_,...) return game.log(...) end})
    game.nicer_tiles=require('mod.class.NicerTiles').new()
    if fixture=='formal' and native_catalog_anchor_enabled then
        require('content_policy').filter_random_boss_talents()
        require('native_catalog_anchor').freeze()
    end
    if not restoring then game.state=State.new{} end
    game.calendar=require("engine.Calendar").new("/data/calendar_allied.lua","%s %s %s %02d %02d",122,167,11)
    game.zone=Zone.castAs({short_name="kernel",name="Kernel",level_range={1,1},base_level=1,_tmp_data={},object_list={},npc_list={},grid_list={}})
    return {Map=Map,Level=Level,Game=Game,Zone=Zone,Grid=Grid,Player=Player,NPC=NPC,rescue=rescue,Party=Party,State=State,noop=noop,logs=logs}
end
local function create(seed, fixture)
    local env=prepare(seed,fixture)
    local Map,Level,Game,Zone,Grid,Player,NPC,rescue,Party,State,noop,logs=env.Map,env.Level,env.Game,env.Zone,env.Grid,env.Player,env.NPC,env.rescue,env.Party,env.State,env.noop,env.logs
    if fixture=='formal' then
        require('native_inputs').install(Game)
        require('native_display_log').install(Game)
        local state=require('formal_scene').create(logs)
        require('native_inputs').bind(state)
        return state
    end
    local map=Map.new(64,64)
    local level=Level.new(1,map)
    local floor=Grid.new{name="floor",type="floor",subtype="floor",display="."}
    local wall=Grid.new{name="wall",type="wall",subtype="wall",display="#",block_move=true,block_sight=true}
    for x=0,63 do for y=0,63 do
        map(x,y,Map.TERRAIN,(x==0 or y==0 or x==63 or y==63 or (x==32 and y>2)) and wall or floor)
        map.lites(x,y,true)
    end end
    game.party=Party.new{}
    local b={name="Probe",faction="allied-kingdoms",max_life=100,life=100,sight=8,lite=1,
        body={INVEN=10,MAINHAND=1,OFFHAND=1,BODY=1,QUIVER=1},stats={str=14,dex=13,con=12},
        combat={dam=8,atk=5,apr=0,physspeed=1,dammod={str=1}}}
    local p=Player.new(b)
    game.party:addMember(p,{main=true,type="player",control="full",orders={}})
    assert(game.party:setPlayer(p))
    assert(game.player==p and p.__CLASSNAME=="mod.class.Player")
    game.level=level
    p.descriptor={world="Maj'Eyal",race="Human",subrace="Cornac",sex="Male",class="Warrior",subclass="Berserker",difficulty="Normal",permadeath="Roguelike"}
    game:setupDifficulty(2)
    game:setupPermadeath(p)
    map:setViewerActor(p)
    p:resolve(); p:resolve(nil,true)
    game.zone:addEntity(game.level,p,"actor",4,4)
    local e=NPC.new{name="Foe",faction="enemies",type="humanoid",subtype="human",level=1,rank=2,fixed_rating=true,
        max_life=100,life=100,sight=8,lite=1,energy={value=0,mod=1},ai="improved_tactical",ai_state={ai_move="move_complex",talent_in=1},
        body={INVEN=10,MAINHAND=1,OFFHAND=1,BODY=1,QUIVER=1},stats={str=12,dex=11,con=12},
        combat={dam=8,atk=5,apr=0,physspeed=1,dammod={str=1}}}
    e:resolve(); e:resolve(nil,true)
    game.zone:addEntity(game.level,e,"actor",5,4)
    p:resetToFull(); e:resetToFull()
    local allies={p}
    for i=1,2 do
        local ally=NPC.new{name="Probe ally "..i,faction="allied-kingdoms",type="humanoid",subtype="human",level=1,rank=2,fixed_rating=true,
            max_life=100,life=100,sight=8,lite=1,energy={value=0,mod=1},ai="improved_tactical",ai_state={ai_move="move_complex",talent_in=1},
            body={INVEN=10,MAINHAND=1,OFFHAND=1,BODY=1,QUIVER=1},stats={str=12,dex=11,con=12},combat={dam=8,atk=5,apr=0,physspeed=1,dammod={str=1}}}
        ally:resolve(); ally:resolve(nil,true)
        game.party:addMember(ally,{type="ally",control="no",orders={}})
        game.zone:addEntity(game.level,ally,"actor",3,3+i*2)
        ally:resetToFull(); allies[#allies+1]=ally
    end
    local enemies={e}
    for i=1,4 do
        local foe=NPC.new{name="Probe foe "..i,faction="enemies",type="humanoid",subtype="human",level=1,rank=2,fixed_rating=true,
            max_life=100,life=100,sight=8,lite=1,energy={value=0,mod=1},ai="improved_tactical",ai_state={ai_move="move_complex",talent_in=1},
            body={INVEN=10,MAINHAND=1,OFFHAND=1,BODY=1,QUIVER=1},stats={str=12,dex=11,con=12},combat={dam=8,atk=5,apr=0,physspeed=1,dammod={str=1}}}
        foe:resolve(); foe:resolve(nil,true)
        game.zone:addEntity(game.level,foe,"actor",9+i,3+(i%3))
        foe:resetToFull(); enemies[#enemies+1]=foe
    end
    -- Fixed engineering loadout. Creation and equipment follow native object APIs.
    local actions=require 'native_actions'
    actions.install_visual_adapter(map)
    world=require('mod.class.World').new()
    core.key={modState=function(k) assert(k=='ctrl'); return false end}
    p:learnTalent(p.T_SHOOT,true,1)
    p:learnTalent(p.T_RUSH,true,1)
    local Object=require 'mod.class.Object'
    game.zone.object_list=Object:loadList('/data/general/objects/bows.lua')
    local function wear(name,slot)
        for _,prototype in ipairs(game.zone.object_list) do
            if prototype.name==name then
                local item=game.zone:finishEntity(game.level,'object',prototype,-1000)
                item:identify(true)
                assert(p:wearObject(item,false,false) and p:getInven(slot)[1]==item)
                return item
            end
        end
        error('missing native equipment '..name)
    end
    wear('elm longbow','MAINHAND')
    wear('quiver of elm arrows','QUIVER')
    game.zone.object_list={}
    if fixture=='skill_types' then require('skill_types').install(p) end
    if fixture=='ranged_policy' then assert(p:move(4,10,true)) end
    if fixture=='exploration' or fixture=='recovery' or fixture=='exploration_complete' then
        for _,foe in ipairs(enemies) do game.level:removeEntity(foe,true) end
        enemies={}
        if fixture=='exploration_complete' then level.all_remembered=true end
    end
    p:resetToFull()
    if fixture=='recovery' then
        p.life=p.life-25
        local q=p:getInven('QUIVER'); q[1].combat.shots_left=q[1].combat.shots_left-5
    end
    p.energy.value=game.energy_to_act
    map.clean_fov=true
    p:doFOV()
    local state={game=game, player=p, enemy=e, allies=allies, enemies=enemies, map=map, Map=Map, logs=logs, visual_emit=map.particleEmitter}
    rescue.bind_party(state)
    if fixture=='rescue' then
        local initial_turn, initial_energy=game.turn,p.energy.value
        p:takeHit(100000,e)
        assert(rescue.is_down(p), 'rescue fixture did not down leader')
        -- Complete this fixture's setup hit with the engine's normal tick-end
        -- callback executor before exposing its initial decision boundary.
        game:onTickEndExecute()
        assert(game.turn==initial_turn and p.energy.value==initial_energy, 'fixture setup advanced time')
        assert(not (game.on_tick_end and next(game.on_tick_end.fcts)) and
            not (game.on_tick_end_custom and next(game.on_tick_end_custom.fcts)) and
            not next(game.__coroutines), 'fixture setup has pending callbacks')
        for _,foe in ipairs(enemies) do game.level:removeEntity(foe,true) end
        state.enemies={}
    end
    require('native_inputs').bind(state)
    return state
end
return {create=create,prepare=prepare}
