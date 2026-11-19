-- Approved timing: one-shot rendering callbacks settle at a native action
-- boundary. Complete input replay reconstructs this queue and its closures.
local M={}
local queue,history,serial,flushing,failure={},{},0,false,nil
local observer
local view_revision,view_actors
local interrupted=false
local interrupt_check
function M.set_interrupt_check(check)interrupt_check=check end
function M.begin_scene()queue={};history={};serial=0;flushing=false;failure=nil;observer=nil;view_revision=nil;view_actors=nil;interrupted=false end
function M.interrupted()return interrupted end
function M.resume_after_confirmation()
 if not interrupt_check or not interrupt_check() then interrupted=false end
end
local function vision_key(a)
 return table.concat({tostring(a.x),tostring(a.y),tostring(a.dead),tostring(a:attr('blind')),tostring(a:attr('sight')),tostring(a.lite),tostring(a.radiance_aura),tostring(a._mercenary_down_serial)},':')
end
function M.bind(state)
 observer=state;view_revision=state.map.__rule_visibility_revision;view_actors={}
 for _,a in ipairs(state.allies)do view_actors[a]=vision_key(a) end
end
local function known_at(item,state)
 -- Never reveal an event using an old vision cache after movement/terrain changes.
 -- A conservative omission does not advance FOV, perception or RNG to log it.
 if not state or state~=observer or state.map.__rule_visibility_revision~=view_revision then return false end
 for a,key in pairs(view_actors or {})do if vision_key(a)~=key then return false end end
 return state and type(item.x)=='number' and type(item.y)=='number' and item.x==math.floor(item.x) and item.y==math.floor(item.y) and item.x>=0 and item.y>=0 and item.x<state.map.w and item.y<state.map.h and state.shared_seen and state.shared_seen[item.x+item.y*state.map.w]
end
function M.has_pending()return #queue>0 or failure~=nil end
function M.export_state()
 assert(not M.has_pending() and not flushing,'pending rule events cannot be saved')
 return {history=history,serial=serial,interrupted=interrupted}
end
function M.import_state(data)
 assert(type(data)=='table' and type(data.history)=='table' and #data.history<=128 and type(data.serial)=='number' and data.serial==math.floor(data.serial) and data.serial>=0 and type(data.interrupted)=='boolean','invalid saved rule event state')
 local last=0
 for _,event in ipairs(data.history)do
  assert(type(event)=='table' and type(event.id)=='number' and event.id==math.floor(event.id) and event.id>last and event.id<=data.serial and (event.phase=='done' or event.phase=='cancelled'),'invalid saved rule event')
  last=event.id
 end
 queue={};history=data.history;serial=data.serial;interrupted=data.interrupted;flushing=false;failure=nil
end
function M.enqueue(handle,callback)
 assert(type(callback)=='function','invalid one-shot rule callback')
 assert(game and game.level,'rule event has no level')
 assert(#queue<4096,'rule event queue capacity reached')
 serial=serial+1
 local item={id=serial,kind='particle_remove:'..handle.def,phase='pending',turn=game.turn,x=handle.x,y=handle.y}
 queue[#queue+1]={item=item,handle=handle,level=game.level}
 return serial
end
function M.flush()
 if failure then error(failure) end
 if flushing then return 0 end
 flushing=true;local count=0
 while #queue>0 do
  if count>=1024 then failure='rule event boundary capacity reached';flushing=false;error(failure) end
  local event=table.remove(queue,1);local item=event.item
  item.observed=not not known_at(item,observer);item.phase='running';count=count+1
  local ok,err=xpcall(function()
   assert(game.level==event.level,'rule event crossed a level boundary')
   local callback=event.handle.on_remove
   if callback then callback(event.handle);item.phase='done' else item.phase='cancelled' end
   event.handle.__rule_event_done=true;event.handle:dieDisplay()
   event.level.map:removeParticleEmitter(event.handle)
  end,debug.traceback)
  item.turn=game.turn
  if not ok then
   item.phase='failed';failure='rule event '..item.id..' failed: '..tostring(err):sub(1,12000)
  end
  history[#history+1]=item;if #history>128 then table.remove(history,1) end
  if failure then flushing=false;error(failure) end
 end
 flushing=false;return count
end
function M.public(state)
 local json=require 'json_validate';local result=json.array()
 local function add(item,pending)
  if item.observed or (pending and known_at(item,state)) then
   result[#result+1]=json.object({id=item.id,kind=item.kind,phase=item.phase,turn=item.turn,x=item.x,y=item.y})
  end
 end
 for _,item in ipairs(history)do add(item)end
 for _,event in ipairs(queue)do add(event.item,true)end
 return result
end
-- Called by reviewed projections after complete native scheduler/NPC actions.
-- Never restart an actor's actBase or change the native iteration cursor.
function M.after_action()
 if not M.has_pending() then return false end
 if require('native_inputs').has_pending() then return false end
 M.flush()
 if interrupt_check and interrupt_check() then interrupted=true;game.paused=true end
 return interrupted
end
return M
