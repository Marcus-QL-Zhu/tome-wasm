dofile('/probe.lua')
local s=require('scene').create(11,'formal')
local Map=require 'engine.Map'
local function dump(tag,x)
 print(tag,'image',tostring(x.image),'image_display',tostring(x.image_display),'moddable_tile',tostring(x.moddable_tile),'female',tostring(x.female))
 if type(x.add_mos)=='table' then for i,v in ipairs(x.add_mos) do if i<=5 then print(tag,'layer',i,tostring(v.image),tostring(v.display_x),tostring(v.display_y)) end end end
end
for _,p in ipairs(s.allies) do dump('VIS_PARTY:'..p.name,p) end
for _,p in ipairs(s.enemies) do dump('VIS_ENEMY:'..p.uid,p) end
local seen={}
for x=0,63 do for y=0,63 do
 local g=s.map(x,y,Map.TERRAIN)
 if g and not seen[g.name] then seen[g.name]=true; dump('VIS_GRID:'..tostring(g.name),g) end
end end
for _,id in ipairs({'T_RUSH','T_SHIELD_WALL','T_GLOOM'}) do local t=s.player:getTalentFromId(id); if t then print('VIS_TALENT',id,tostring(t.image)) end end
