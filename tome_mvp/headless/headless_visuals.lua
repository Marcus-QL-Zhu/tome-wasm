-- Rendering-only particle handles. Native actors, projectiles and callbacks
-- stay in their own engine classes. No particle scripts or RNG execute here.
local M={}
local methods={}
local backend={}
function backend:die() self.dead=true end
function backend:isAlive() return not self.dead end
function backend:shift() end
function backend:toScreen() end
function backend:setSub(child) self.sub=child end
local backend_meta={__index=backend}
local owned=setmetatable({},{__mode='k'})
function methods:loaded() self.dead=false; self.ps=setmetatable({},backend_meta) end
function methods:cloned() self:loaded() end
function methods:checkDisplay() end
function methods:dieDisplay() self.dead=true; if self.ps then self.ps:die() end end
function methods:updateZoom() self.zoom=self.zoom or 1 end
function methods:shift() end
function methods:shiftCustom() end
function methods:setSub(def,radius,args,shader)
    self.subps=M.new(def,radius,args,shader)
    self.ps:setSub(self.subps.ps)
end
local meta={__index=methods,__newindex=function(self,key,value)
    -- Only one-shot removal callbacks have an approved replacement timing.
    if key=='on_remove' and value~=nil then
        assert(type(value)=='function','invalid removal rule callback')
        rawset(self,key,value)
        if not rawget(self,'__rule_event_id') then rawset(self,'__rule_event_id',require('rule_events').enqueue(self,value)) end
        return
    end
    if value~=nil and (key=='on_update' or key=='update') then
        error('unsupported_rule_bearing_visual_callback:'..key)
    end
    rawset(self,key,value)
end}
function M.snapshot_metatype(t)
 local mt=getmetatable(t)
 if mt==meta then
  assert(not rawget(t,'on_remove') and not rawget(t,'on_update') and not rawget(t,'update'),'visual rule callback cannot be snapshotted')
  return 'visual'
 end
 if mt==backend_meta then return 'visual_backend' end
end
function M.restore_metatype(t,kind)
 if kind=='visual' then setmetatable(t,meta)
 elseif kind=='visual_backend' then setmetatable(t,backend_meta)
 else error('unknown visual metatype') end
end
local function finite_or_nil(v)
 return v==nil or type(v)=='number' and v==v and v~=math.huge and v~=-math.huge
end
local dream_palette={rm=0,rM=0,gm=180,gM=255,bm=180,bM=255,am=35,aM=90}
local function snapshot_display_args(h)
 local args=h.args
 if type(args)~='table' or getmetatable(args) then return false end
 if not next(args) then return true end
 if h.def~='generic_teleport' then return false end
 local count=0
 for key,value in pairs(args) do
  if dream_palette[key]~=value then return false end
  count=count+1
 end
 return count==8
end
local function only_weak_display_handles(m)
 if next(m.pending) then return false end
 local any=false
 for h in pairs(m.active)do
  any=true
  if getmetatable(h)~=meta or type(h.def)~='string' or h.def~=h.__headless_visual or h.dead~=false or getmetatable(h.ps)~=backend_meta or next(h.ps) then return false end
  if not snapshot_display_args(h) then return false end
  if not finite_or_nil(h.radius) or not finite_or_nil(h.zoom) or not finite_or_nil(h.x) or not finite_or_nil(h.y) or not finite_or_nil(h.zdepth) then return false end
  for k in pairs(h)do
   if k~='__headless_visual' and k~='def' and k~='radius' and k~='args' and k~='zoom' and k~='dead' and k~='ps' and k~='x' and k~='y' and k~='zdepth' then return false end
  end
 end
 return any
end
local function pin_other_maps(map)
 local pins={}
 for other,m in pairs(owned)do if other~=map then
  for h in pairs(m.active)do pins[#pins+1]=h end
  for h in pairs(m.pending)do pins[#pins+1]=h end
 end end
 return pins
end
function M.assert_snapshot_safe(map)
 local m=owned[map]
 if m and only_weak_display_handles(m) then
  local pins=pin_other_maps(map)
  collectgarbage('collect')
  assert(type(pins)=='table') -- retain other maps' weak handles through GC
 end
 assert(not m or (not next(m.active) and not next(m.pending)),'active map-owned particle cannot be snapshotted')
end
function M.dismiss_terminal(map)
 assert(not require('rule_events').has_pending(),'terminal visual rules still pending')
 local m=owned[map]
 if not m then return end
 for h in pairs(m.active)do
  assert(getmetatable(h)==meta and not h.on_update and not h.update
    and (not h.on_remove or h.__rule_event_done),'terminal visual still owns a rule callback')
  rawset(h,'on_remove',nil)
  h:dieDisplay()
  m.active[h]=nil
  m.pending[h]=nil
 end
end
function M.new(def,radius,args,shader)
    assert(type(def)=='string' and #def>0 and #def<=256,'invalid visual particle name')
    assert(radius==nil or (type(radius)=='number' and radius==radius),'invalid visual radius')
    assert(args==nil or type(args)=='table','invalid visual arguments')
    local h=setmetatable({__headless_visual=def,def=def,radius=radius or 1,args=args or {},shader=shader,zoom=1},meta)
    h:loaded()
    return h
end
function M.install_map(map)
    local Map=require 'engine.Map'
    if not M.map_installed then
      M.map_installed=true
      local function members(self)
        if not owned[self] then owned[self]={active=setmetatable({},{__mode='k'}),pending=setmetatable({},{__mode='k'})} end
        return owned[self]
      end
      local add,remove,flush=Map.addParticleEmitter,Map.removeParticleEmitter,Map.removeParticleEmitters
      Map.addParticleEmitter=function(self,h,x,y)
        if type(h)=='table' and h.__headless_visual then
          local m=members(self);if m.active[h] then return false end
          if x~=nil and y~=nil then h.x=x;h.y=y end
          m.active[h]=true;return h
        end
        return add(self,h,x,y)
      end
      Map.removeParticleEmitter=function(self,h)
        if type(h)=='table' and h.__headless_visual then
          local m=members(self);if not m.active[h] then return false end
          m.pending[h]=true;return true
        end
        if type(h)~='table' then return false end
        return remove(self,h)
      end
      Map.removeParticleEmitters=function(self)
        local m=members(self)
        for h in pairs(m.pending) do h:dieDisplay();m.active[h]=nil end
        m.pending=setmetatable({},{__mode='k'});return flush(self)
      end
    end
    map.particleEmitter=function(_,x,y,radius,def,args,shader,zdepth)
        local h=M.new(def,radius,args,shader); h.x=x; h.y=y; h.zdepth=zdepth
        map:addParticleEmitter(h)
        return h
    end
end
return M
