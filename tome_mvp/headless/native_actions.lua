local M = {}
local entries=require('skill_types').entries
local byid={}; for _,e in ipairs(entries) do byid[e.id]=e end
function M.target_kind(id)
 if not require('content_policy').allowed_talent(id) then return nil end
 if byid[id] then return byid[id].target end
 local p=game and game.player;local t=p and p:knowTalent(id) and p:getTalentFromId(id)
 if t and t.mode~='passive' then return 'native' end
end
function M.install_visual_adapter(map)
 if not M.error_reporting_installed then
  M.error_reporting_installed=true
  local interface=require 'engine.interface.ActorTalents'
  local original=interface.onTalentLuaError
  local function report(self,talent,err)
   local json=require 'json_validate'
   print('HEADLESS_TALENT_ERROR_STACK_JSON',json.encode(json.object({talent=tostring(talent and talent.id),actor=self.uid,error=tostring(err):sub(1,32768)})))
   return original(self,talent,err)
  end
  interface.onTalentLuaError=report
  for _,name in ipairs({'mod.class.Actor','mod.class.Player','mod.class.NPC','mod.class.PartyMember'}) do require(name).onTalentLuaError=report end
 end
 -- ActorTemporaryEffects:effectParticles only adds graphical attachments.
 -- Gameplay effects, callbacks and temporary values remain native.
 local effect_visuals={}
 local function effect_particles(_,effect,...)
  assert(type(effect)=='table','invalid effect visual owner')
  for _,descriptor in ipairs({...}) do
   assert(type(descriptor)=='table' and type(descriptor.type)=='string','unclassified effect visual')
   effect_visuals[descriptor.type]=(effect_visuals[descriptor.type] or 0)+1
  end
 end
 for _,name in ipairs({'engine.interface.ActorTemporaryEffects','mod.class.Actor','mod.class.NPC','mod.class.PartyMember','mod.class.Player'}) do
  require(name).effectParticles=effect_particles
 end
 local visuals=require 'headless_visuals'
 visuals.install_map(map)
 local Projectile=require 'mod.class.Projectile'
 local make=Projectile.makeProject
 function Projectile:makeProject(src,display,...)
  display=table.clone(display or {})
  -- These three fields are rendering metadata in engine.Projectile.makeProject.
  -- Keep def, velocity, movement, impact and stop callbacks untouched.
  display.particle=nil; display.trail=nil; display.particle_args=nil
  return make(self,src,display,...)
 end
 local Particles=require 'engine.Particles'
 Particles.new=visuals.new
 for _,class in ipairs({require 'engine.Entity',require 'mod.class.Actor',require 'mod.class.Player',require 'mod.class.NPC',require 'mod.class.PartyMember',require 'mod.class.Projectile'}) do
  local add,remove=class.addParticles,class.removeParticles
  class.addParticles=function(self,ps) if ps and ps.__headless_visual then ps.x=self.x;ps.y=self.y;return ps end return add(self,ps) end
  class.removeParticles=function(self,ps) if ps and ps.__headless_visual then ps:dieDisplay();return end return remove(self,ps) end
 end
end
local function talent_status(p,id)
 if not require('content_policy').allowed_talent(id) then return false,'content_policy' end
 if not id or not p:knowTalent(id) then return false,'not_learned' end
 local t=p:getTalentFromId(id)
 if not t then return false,'unknown_talent' end
 if p:isTalentCoolingDown(t) then return false,'cooldown',t end
 if not p:preUseTalent(t,true,true) then return false,'unavailable',t end
 return true,nil,t
end
local function target_status(p,target,t)
 if not target or target.dead or not target.x or not target.y then return false,'invalid_target' end
 if p:reactionToward(target)>=0 or not p:canSee(target) then return false,'invalid_target' end
 if t.id==p.T_RUSH and core.fov.distance(p.x,p.y,target.x,target.y)<=1 then return false,'too_close' end
 if not p:canProject(p:getTalentTarget(t),target.x,target.y) then return false,'blocked_target' end
 return true
end
function M.valid_targets(p,id,actors)
 local ids=require('json_validate').array()
 local t=p:getTalentFromId(id)
 if t then for _,a in ipairs(actors) do
  if target_status(p,a,t) then ids[#ids+1]=a.uid end
 end end
 return ids
end
function M.menu(p)
 local out={}
 for _,entry in ipairs(entries) do
  local id=p[entry.id]; local ok,reason,t=talent_status(p,id)
  if t then
   local resources=require("json_validate").object({})
   for _,key in ipairs({'mana','stamina','positive','sustain_mana','sustain_stamina','sustain_positive'}) do
    local v=t[key]; if type(v)=='function' then v=v(p,t) end
    if type(v)=='number' then resources[key]=v end
   end
   out[#out+1]={id=entry.id,name=t.name,mode=t.mode or 'activated',target=entry.target,available=ok,reason=reason,
    cooldown=p:isTalentCoolingDown(t) or false,resources=resources,active=not not p:isTalentActive(id),no_energy=not not util.getval(t.no_energy,p,t)}
  end
 end
 -- Other learned skills enter the original coroutine input path.
 -- Catalog availability is separate from execution and rule coverage.
 local extra={}
 for id in pairs(p.talents) do
  local t=p:getTalentFromId(id)
  if t and not byid[id] and id~=p.T_SHOOT and not t.hide and (t.mode=='activated' or t.mode=='sustained' or t.mode=='passive') then
   local target_type=type(t.target)=='table' and t.target.type or nil
   local category=(target_type=='bolt' or target_type=='beam' or target_type=='ball' or target_type=='hit') and target_type or 'needs_input'
   local available,why=talent_status(p,id)
   extra[#extra+1]={id=id,name=t.name,mode=t.mode,target=t.mode=='passive' and 'unknown' or 'native',target_schema=category,available=t.mode~='passive' and available,reason=t.mode=='passive' and 'passive' or why,
    cooldown=p:isTalentCoolingDown(t) or false,resources=require('json_validate').object({}),active=not not p:isTalentActive(id)}
  end
 end
 table.sort(extra,function(x,y) return x.id<y.id end)
 for _,item in ipairs(extra) do out[#out+1]=item end
 for _,item in ipairs(out) do
  local t=p:getTalentFromId(item.id)
  item.icon_key=item.id
  item.icon=require('visual_metadata').icon(t.image)
  local ok,range=pcall(function() return p:getTalentRange(t) end)
  if ok and type(range)=='number' then item.range=range end
  item.melee_target=item.target=='hostile' and item.range==1
  local desc_ok,desc=pcall(function() return tostring(p:getTalentFullDescription(t)) end)
  if desc_ok and type(desc)=='string' then item.description=desc end
  local costs=require('json_validate').object({})
  for _,r in ipairs(p.resources_def or {}) do
   local success,cost=pcall(function()
    local value=t[r.short_name] and util.getval(t[r.short_name],p,t) or 0
    value=p:alterTalentCost(t,r.short_name,value)
    return value*(util.getval(r.cost_factor,p,t,false,value) or 1)
   end)
   if success and type(cost)=='number' and cost~=0 then costs[r.short_name]=cost end
  end
  item.effectivecost=costs
 end
 return out
end
local function native_result(p,result)
 if p.talent_error then error('native talent reported a script error') end
 if require('native_inputs').has_pending() then return true,'input_pending' end
 if result then return true end
 -- ToME returns nil/false for ordinary failed or cancelled casts too.
 -- Confusion can spend energy before returning false. Exceptions still throw;
 -- a swallowed talent error or unfinished input must never become a success.
 if p.talent_error then error('native talent reported a script error') end
 if next(game.__coroutines or {}) or next(game.dialogs or {}) then error('native talent awaiting unsupported input') end
 return true,'native_declined'
end
function M.use(p,id,target)
 local entry=byid[id] or (M.target_kind(id)=='native' and {target='native'}); if not entry then return false,'unsupported_talent' end
 local ok,reason,t=talent_status(p,p[id]); if not ok then return false,reason end
 if entry.target=='hostile' then local valid,why=target_status(p,target,t); if not valid then return false,why end
 elseif entry.target=='grid' then
  if type(target)~='table' or type(target.x)~='number' or type(target.y)~='number' or target.x~=math.floor(target.x) or target.y~=math.floor(target.y) then return false,'invalid_target' end
  if target.x<0 or target.y<0 or target.x>=game.level.map.w or target.y>=game.level.map.h then return false,'invalid_target' end
  if not p:canProject(p:getTalentTarget(t),target.x,target.y) then return false,'blocked_target' end
  target={x=target.x,y=target.y,__no_self=true}
 end
 return native_result(p,p:useTalent(p[id],nil,nil,nil,target,false,true))
end
function M.can_shoot(p)
 local ok=talent_status(p,p.T_SHOOT)
 return ok
end
function M.shoot(p,target)
 local ok,reason,t=talent_status(p,p.T_SHOOT); if not ok then return false,reason end
 local valid,why=target_status(p,target,t); if not valid then return false,why end
 return native_result(p,p:useTalent(p.T_SHOOT,nil,nil,nil,target,false,true))
end
return M
