dofile('/probe.lua')
local s=require('scene').create(12,'exploration');local vis=require('visibility');local rescue=require('rescue')
local p,a,e,m,M=s.player,s.allies[2],s.enemy,s.map,s.Map
game.level:removeEntity(s.allies[3],true);s.allies={p,a}
local grid=require('mod.class.Grid'):loadList('/data/general/grids/basic.lua');game.zone.grid_list=grid
for y=1,62 do m(10,y,M.TERRAIN,grid.WALL) end
for y=1,9 do for x=12,24 do m.lites(x,y,false) end end
assert(a:move(16,4,true));a.lite=3;e.lite=0;game.zone:addEntity(game.level,e,'actor',18,4);s.enemies={e}
m.clean_fov=true;p:doFOV();local initial_turn=game.turn;local primary=m.seens(18,4);local actor_fov=a.fov
local function check(label,expect)
 vis.refresh(s);local seen=not not s.shared_seen[18+4*m.w];local foe=not not s.visible[e.uid]
 assert(seen==expect and foe==expect,label..' incorrect sharing')
 assert(not s.player_visible[e.uid] and m.seens(18,4)==primary and a.fov==actor_fov and game.turn==initial_turn,label..' changed primary FOV, actor FOV, or time')
 assert(not s.shared_seen[22+4*m.w],label..' reveals beyond light')
 protocol_write(label..' tile='..tostring(seen)..' enemy='..tostring(foe)..' primary=false turn='..game.turn..'\n')
end
check('lit',true);a.lite=0;check('dark',false);a.lite=3;a.blind=1;check('blind',false);a.blind=nil
m(17,4,M.TERRAIN,grid.WALL);check('wall',false);m(17,4,M.TERRAIN,grid.FLOOR)
a:takeHit(100000,e);assert(rescue.is_down(a));check('down',false)
protocol_write('PASS_ALLY_LIGHT_BOUNDARIES\n')
