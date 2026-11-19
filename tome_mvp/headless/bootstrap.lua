local function boot()
    local list = dofile("/directories.lua")
    local function norm(p) return (p:gsub("[/]+","/"):gsub("/$","")) end
    fs={}
    fs.list=function(p) return list[norm(p)] or {} end
    fs.exists=function(p)
        p=norm(p)
        if list[p] then return true end
        local parent,name=p:match("^(.*)/([^/]*)$")
        for _,v in ipairs(list[parent] or {}) do if v==name then return true end end
        return false
    end
    fs.isDirectory=function(p) return list[norm(p)]~=nil end
    local surface_methods,font_methods={},{size=function(self,s) return #s,1 end,lineSkip=function() return 1 end,getStyle=function() return "normal" end,setStyle=function() end}
    core.display={
        newSurface=function() return setmetatable({}, {__index=surface_methods}) end,
        newFont=function() return setmetatable({}, {__index=font_methods}) end,
    }
    core.game={getTime=function() return os.clock()*1000 end}
    core.shader={active=function() return false end,allow=function() return false end}
    __uids={}
    setmetatable(rng,rng)
    dofile("/loader/pre-init.lua")
    dofile("/engine/utils.lua")
    dofile("/engine/colors.lua")
    dofile("/engine/resolvers.lua")
    local config=require("config")
    require("engine.I18N")
    config.settings.font_scale=config.settings.font_scale or 100
    local FontPackage=require("engine.FontPackage")
    FontPackage:loadDefinition("/data/font/packages/default.lua")
    FontPackage:setDefaultId("basic")
    config.settings.audio={enable=false}
    config.settings.tome={gfx={tiles="ascii",size="16x16"}}
    profile={mod={allow_build={}},data_log={log={}},isDonator=function() return false end}
    function profile:incrDataProfile(name,data)
        self.data_log.log[#self.data_log.log+1]={module='tome',kind=name,data=data}
    end
    profile.error_reports={}
    function profile:currentCharacter(version,label,uuid)
        -- Native party level-up updates account presence. Keep that metadata
        -- local; no account, network request or desktop integration is used.
        self.current_character={version=version or (game and game.__mod_info and game.__mod_info.version_string),label=label,uuid=uuid}
    end
    function profile:sendError(message,details)
        -- Native reporting returns after submitting the report. Retain that
        -- control flow locally without uploading profile data.
        local report={message=tostring(message):sub(1,2048),details=tostring(details):sub(1,8192)}
        self.error_reports[#self.error_reports+1]=report
        if #self.error_reports>500 then table.remove(self.error_reports,1) end
        local json=require 'json_validate'
        print('NATIVE_LOCAL_ERROR_REPORT_JSON',json.encode(json.object(report)))
    end
    dofile("/mod/settings.lua")
    local Map=require("engine.Map")
    Map.tiles=Map.tiles or {}
    Map.tiles.no_moddable_tiles=true
    local level=require("engine.Level")
    level.remove_old_entity_on_duplicate=true
    dofile("/rules.lua")
    local birther=require("engine.Birther")
    package.loaded["mod.dialogs.Birther"]={getBirthField=function(_,...) return birther:getBirthField(...) end}
    local Actor=require("mod.class.Actor")
    local NPC=require("mod.class.NPC")
    local Player=require("mod.class.Player")
    class:runInherited()
    local talents=require("engine.interface.ActorTalents")
    require('yieldable_talents').install()
    local effects=require("engine.interface.ActorTemporaryEffects")
    local ai=require("engine.interface.ActorAI")
    local function count(t) local n=0 for _ in pairs(t) do n=n+1 end return n end
    require('localization').initialize()
    print("PASS_REGISTRY",count(talents.talents_def),count(effects.tempeffect_def),type(ai.ai_def.improved_tactical),type(Actor.attackTarget),type(NPC.act),type(Player.doFOV))
end
local ok, err=xpcall(boot,debug.traceback)
if not ok then error(err) end
