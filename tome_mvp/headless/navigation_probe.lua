dofile('/probe.lua')
local s=require('scene').create(11,'exploration')
local visibility=require 'visibility'
local nav=require 'navigation'
visibility.refresh(s); nav.capture(s,s.player)
local p=s.player
local path,x,y
for yy=1,62 do for xx=1,62 do
 if not path and math.max(math.abs(xx-p.x),math.abs(yy-p.y))>=3 then
  local candidate=nav.path(s,p,xx,yy)
  if candidate and #candidate>=3 then path,x,y=candidate,xx,yy end
 end
end end
assert(path,'no suitable known path')
local function signature(route)
 local parts={}; for _,n in ipairs(route or {}) do parts[#parts+1]=n.x..','..n.y end; return table.concat(parts,';')
end
local expected=signature(path)
local tile=path[2]; local index=tile.x+tile.y*s.map.w
s.shared_seen[index]=nil
local cell=s.map.map[index]
local oldterrain,oldactor=cell[s.Map.TERRAIN],cell[s.Map.ACTOR]
local wall=s.map(0,0,s.Map.TERRAIN)
cell[s.Map.TERRAIN]=wall
assert(signature(nav.path(s,p,x,y))==expected,'hidden wall changed path')
cell[s.Map.ACTOR]=s.enemies[1]
assert(signature(nav.path(s,p,x,y))==expected,'hidden actor changed path')
cell[s.Map.TERRAIN],cell[s.Map.ACTOR]=oldterrain,oldactor
local blocked_index
for i,entry in pairs(s.navigation_memory) do if entry.blocked then blocked_index=i; break end end
assert(blocked_index,'no remembered wall')
s.shared_seen[blocked_index]=nil
local blocked_cell=s.map.map[blocked_index]
local blocked_terrain=blocked_cell[s.Map.TERRAIN]
blocked_cell[s.Map.TERRAIN]=oldterrain
assert(signature(nav.path(s,p,x,y))==expected,'hidden wall removal changed path')
blocked_cell[s.Map.TERRAIN]=blocked_terrain
protocol_write('PASS_NAVIGATION_HIDDEN_TERRAIN_ACTOR\n')
