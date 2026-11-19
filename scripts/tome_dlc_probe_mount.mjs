// Appended to the locally generated installed-rule manifest by prepare_tome_dlc_probe.py.
export function mountDlc(mod) {
 if(mod.installedDlcRules)return;
 const fs=mod.FS;
 for(const [path,src] of Object.entries(files)){
  fs.mkdirTree(path.slice(0,path.lastIndexOf('/')));
  fs.writeFile(path,src);
 }
 function insert(path,anchor,code){
  const source=fs.readFile(path,{encoding:'utf8'});
  if(source.split(anchor).length!==2)throw Error('unknown DLC bootstrap boundary: '+anchor);
  fs.writeFile(path,source.replace(anchor,()=>code+anchor));
 }
 insert('/bundle/generated/probe.lua','    local function norm',`    for p,added in pairs(dofile("/dlc_directories.lua")) do
        local names=list[p] or {};list[p]=names;local seen={}
        for _,n in ipairs(names) do seen[n]=true end
        for _,n in ipairs(added) do if not seen[n] then names[#names+1]=n end end
        table.sort(names)
    end
`);
 insert('/bundle/generated/probe.lua','    dofile("/engine/utils.lua")','    dofile("/dlc_loader.lua")\n');
 insert('/bundle/generated/probe.lua','    dofile("/rules.lua")',`    package.loaded["engine.Module"]=setmetatable({}, {__index=function(_,k) error("unavailable desktop module operation "..k) end})
    dofile("/dlc_hooks.lua")
`);
 // Addon startup registers display entities before the campaign is restored.
 // Give these definitions their own UID range and retain the base game's cursor.
 insert('/bundle/engine/engine/Entity.lua','function _M.native_uid_state()',`function _M.loadAddonDefinitions(load)
    local gameplay_uid = next_uid
    assert(gameplay_uid < 0x40000000 and not native_uid_restore)
    next_uid = 0x40000000
    load()
    next_uid = gameplay_uid
end
`);
 insert('/bundle/generated/rules.lua','require("mod.class.interface.ActorAI").AI_InitializeData()', `require("mod.class.interface.PartyLore"):loadDefinition("/data/lore/lore.lua")
require("engine.Entity").loadAddonDefinitions(function() class:triggerHook{"ToME:load"} end)
`);
 mod.installedDlcRules=true;
}
