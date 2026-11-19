-- UI-only coroutine adapter. Original talent actions still own all rule effects.
local M={}
local active,serial,state
local function request(kind,data,respond)
 serial=(serial or 0)+1;active={id=serial,kind=kind,data=data or {},respond=respond}
 return active
end
M.request=request
function M.clear_dialog(d)if active and active.data.dialog==d then active=nil end end
function M.bind(s)state=s end
function M.has_pending()return active~=nil end
function M.export_state() assert(not active,'native input pending');return {serial=serial or 0} end
function M.import_state(data)
 assert(not active and type(data)=='table' and type(data.serial)=='number' and data.serial==math.floor(data.serial) and data.serial>=0 and data.serial<9007199254740991,'invalid native input serial')
 serial=data.serial
end
function M.validate(answer)
 if not active or answer.input_id~=active.id then return false,'stale_input' end
 if active.kind=='quantity' and not answer.cancel and (type(answer.value)~='number' or answer.value~=answer.value or math.abs(answer.value)==math.huge or (active.data.min and answer.value<active.data.min) or (active.data.max and answer.value>active.data.max)) then return false,'invalid_quantity' end
 if active.kind=='choice' and not answer.cancel and (type(answer.choice)~='number' or answer.choice~=math.floor(answer.choice) or not active.data.options[answer.choice]) then return false,'invalid_choice' end
 if active.kind=='target' and not answer.cancel then
  local x,y=answer.x,answer.y
  if type(x)~='number' or type(y)~='number' or x~=math.floor(x) or y~=math.floor(y) or x<0 or y<0 or x>=game.level.map.w or y>=game.level.map.h then return false,'invalid_target' end
  if active.data.requires_knowledge and not state.terrain_memory[x+y*state.map.w] then return false,'unexplored_target' end
 end
 return true
end
function M.public()
 if not active then return require('json_validate').null end
 local json=require 'json_validate';local out=json.object({id=active.id,kind=active.kind,prompt=tostring(active.data.prompt or '选择技能目标')})
 for _,k in ipairs({'range','radius','target_type','min','max','default'}) do if type(active.data[k])=='number' or type(active.data[k])=='string' then out[k]=active.data[k] end end
 if active.data.options then
  out.options=json.array()
  for _,o in ipairs(active.data.options) do out.options[#out.options+1]=json.object({id=o.id,label=o.label}) end
 end
 return out
end
function M.choose_object(object)
 assert(active and active.kind=='choice','native inventory choice unavailable')
 for i,choice in ipairs(active.data.options or {})do
  if choice.object==object then return M.respond({input_id=active.id,choice=i}) end
 end
 error('native inventory choice was not offered')
end

function M.respond(answer)
 assert(M.validate(answer),'invalid native input')
 local previous=active;active=nil
 require('ai_input_task').note_answer(answer)
 local ok,err=xpcall(function()previous.respond(answer)end,debug.traceback)
 if not ok then active=nil;error(err) end
end
function M.install(Game)
 if M.installed then return end;M.installed=true
 require('native_dialogs').install(Game,M)
 function Game:targetGetForPlayer(typ)
  if self.target.forced then return unpack(self.target.forced) end
  if not typ then local t=self.target.target;return t.x,t.y,t.entity end
  if type(typ)=='string' then typ={msg=typ} end
  local co=assert(coroutine.running(),'target selection requires a talent coroutine')
  request('target',{prompt=typ.msg or '选择技能目标',target_type=typ.type or 'hit',range=typ.range,radius=typ.radius,requires_knowledge=typ.requires_knowledge~=false},function(answer)
   local x,y,a
   if not answer.cancel then
    x,y=answer.x,answer.y
    assert(type(x)=='number' and type(y)=='number' and x==math.floor(x) and y==math.floor(y) and x>=0 and y>=0 and x<game.level.map.w and y<game.level.map.h,'invalid target coordinates')
    if typ.requires_knowledge~=false then assert(state and state.terrain_memory[x+y*state.map.w],'unexplored target') end
    a=game.level.map(x,y,require('engine.Map').ACTOR)
    if a then
     local visible=state.visible[a.uid]
     for _,ally in ipairs(state.allies) do if ally==a then visible=true end end
     if not visible then a=nil end
    end
    game.target.target={x=x,y=y,entity=a}
   end
   local ok,err=require('ai_input_task').resume_native(co,x,y,a);if not ok then error(err) end
  end)
  return coroutine.yield()
 end
end
return M
