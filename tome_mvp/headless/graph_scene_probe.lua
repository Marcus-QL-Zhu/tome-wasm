-- Diagnostic only: discovers unsupported leaves before any save is enabled.
dofile('/probe.lua')
local state=require('scene').create(11)
local codec=require 'graph_codec'
for j=1,5 do
    state.player:waitTurn()
    for i=1,30 do if game.paused and state.player:enoughEnergy() then break end; game:tick() end
    state.map.clean_fov=true; state.player:doFOV()
end
local anchors={}
local function anchor(v,name)
    if v~=nil and not anchors[v] then anchors[v]=name end
end
local seen={}
local function scan(v)
    if type(v)~='table' or seen[v] then return end
    seen[v]=true
    local mt=debug.getmetatable(v)
    local cname=rawget(v,'__CLASSNAME')
    if cname and mt and type(mt.__index)=='table' then anchor(mt.__index,'class:'..cname) end
    for k,x in next,v do scan(k); scan(x) end
end
scan(state.game)
anchor(state.Map,'class:engine.Map'); anchor(state.Map.call,'method:engine.Map.call')
local game=state.game
anchor(game.log,'host:log'); anchor(game.logNewest,'host:logNewest'); anchor(game.logRollback,'host:logRollback')
anchor(game.playSound,'host:noop'); anchor(game.playSoundNear,'host:noop')
anchor(debug.getmetatable(game.uiset.logdisplay).__call,'host:logdisplay')
for _,actor in ipairs(state.allies) do
    anchor(actor.addEntityOrder,'actor:'..actor.uid..':addEntityOrder')
    anchor(actor.regenResourcesFast,'actor:'..actor.uid..':regenResourcesFast')
end
for _,actor in ipairs(state.enemies) do anchor(actor.regenResourcesFast,'actor:'..actor.uid..':regenResourcesFast') end
local m=state.map
local metatables={[m.seens]=true,[m.infovs]=true,[m.has_seens]=true,[m.remembers]=true,[m.lites]=true,[m.attrs]=true}
local omitted={_map=true,_fovcache=true,_check_entities=true,_check_entities_store=true,path_strings_computed=true}
local doc=codec.encode({game=game,allies=state.allies,enemies=state.enemies,logs=state.logs},anchors,30000,{
    skip=function(t,k) return t==m and omitted[k] end,
    skipmeta=function(t) return metatables[t] end,
})
local json=require 'json_validate'
local encoded=json.encode(doc)
protocol_write('GRAPH_NODES '..#doc.nodes..' BYTES '..#encoded..'\n')
assert(json.decode(encoded),'graph exceeded decoder limits')
