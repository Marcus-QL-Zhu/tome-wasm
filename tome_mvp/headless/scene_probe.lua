dofile("/probe.lua")
local function run()
    core.display.getModesList=function() return {} end
    package.loaded["engine.Module"]=setmetatable({}, {__index=function(_,k) error("unavailable desktop module operation "..k) end})
    core.fov.set_algorithm("large_ass")
    core.fov.set_permissiveness(0.01)
    core.fov.set_actor_vision_size(1)
    core.fov.set_vision_shape("circle")
    local Map=require "engine.Map"
    local Level=require "engine.Level"
    local Game=require "mod.class.Game"
    local Zone=require "mod.class.Zone"
    local Grid=require "mod.class.Grid"
    local Player=require "mod.class.Player"
    local NPC=require "mod.class.NPC"
    local Party=require "mod.class.Party"
    local State=require "mod.class.GameState"
    local noop=function() end
    local layer={setObscure=noop,setShown=noop,setupGridLines=noop,setDefaultShader=noop,zCallback=noop,setImportant=noop,setGrid=noop,setLite=noop,setSeen=noop,setRemember=noop,setScroll=noop,cleanSeen=noop}
    core.map={newMap=function() return layer end}
    core.game.checkError=function() return nil end
    core.game.requestNextTick=function() end
    savefile_pipe={saving=false}
    Map.viewport={width=16,height=16,mwidth=16,mheight=16}
    Map.tile_w,Map.tile_h=1,1
    Map.updateMapDisplay=function(self,x,y)
        local g=self(x,y,Map.TERRAIN)
        if not g then return end
        for _,ps in ipairs(self.path_strings) do
            self._fovcache.path_caches[ps]:set(x,y,g:check("block_move",x,y,self.path_strings_computed[ps] or ps,false,true))
        end
    end
    rng.seed(11)
    game=Game.castAs({
        energy_to_act=1000,energy_per_tick=100,can_pause=true,turn=0,paused=true,
        entities=setmetatable({},{__mode="v"}),__coroutines={},delayed_log_messages={},delayed_log_damage={},
        dialogs={},uniques={},player_name="Probe",tiles_attachements={},tiles_facing={},
        uiset={hotkeys_display={}},target={target={}},
        log=function(...) print("EVENT",...) end,playSoundNear=noop,playSound=noop,
    })
    local logs={}
    game.log=function(fmt,...) local t={str=string.format(fmt,...)}; logs[#logs+1]=t end
    game.logNewest=function() local l=logs[#logs]; if l then return l.str,l end end
    game.logRollback=function(l) while #logs>0 and logs[#logs]~=l do logs[#logs]=nil end end
    game.state=State.new{}
    game.calendar=require("engine.Calendar").new("/data/calendar_allied.lua","%s %s %s %02d %02d",122,167,11)
    game.zone=Zone.castAs({short_name="kernel",name="Kernel",level_range={1,1},base_level=1,_tmp_data={},object_list={},npc_list={},grid_list={}})
    local map=Map.new(16,16)
    local level=Level.new(1,map)
    local floor=Grid.new{name="floor",type="floor",subtype="floor",display="."}
    local wall=Grid.new{name="wall",type="wall",subtype="wall",display="#",block_move=true,block_sight=true}
    for x=0,15 do for y=0,15 do
        map(x,y,Map.TERRAIN,(x==0 or y==0 or x==15 or y==15 or (x==8 and y>2)) and wall or floor)
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
    p.energy.value=game.energy_to_act
    map.clean_fov=true
    p:doFOV()
    print("FOVTRACE",p.__CLASSNAME,debug.getinfo(p.doFOV).short_src,debug.getinfo(p.computeFOV).short_src,tostring(p:attr("blind")),p.fov and #p.fov.actors_dist,map._fovcache.block_sight:get(5,4),map._fovcache.block_sight:get(4,4),map.infovs(4,4),map.seens(4,4))
    local cn=0
    p:computeFOV(8,"block_sight",function() cn=cn+1 end,true,false,true)
    print("FOVCOUNT",cn)
    assert(map.seens(5,4) and not map.seens(10,4),table.concat({tostring(p.x),tostring(p.y),tostring(e.x),tostring(e.y),tostring(map.seens(5,4)),tostring(map.seens(10,4)),tostring(map._fovcache.block_sight:get(8,4)),tostring(map.lites(5,4)),tostring(map.infovs(5,4)),tostring(p.sight)},","))
    print("PASS_FOV",p.uid,e.uid,map.seens(5,4),map.seens(10,4),p:reactionToward(e))
    local old_p,old_e=p.life,e.life
    p:move(e.x,e.y)
    local paid=p.energy.value
    assert(paid<game.energy_to_act)
    local ticks=0
    repeat game:tick(); ticks=ticks+1 until (game.paused and p:enoughEnergy()) or ticks>30
    assert(game.paused and p:enoughEnergy())
    print("PASS_NATIVE_ACTION",ticks,game.turn,old_p,p.life,old_e,e.life,paid,p.energy.value,e.ai,e.ai_target.actor==p)
end
local ok,err=xpcall(run,debug.traceback)
if not ok then error(err) end
