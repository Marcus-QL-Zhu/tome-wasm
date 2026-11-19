-- Suspend the complete authorized AI frame, not just its talent coroutine.
-- The original talent owns costs, cancellation and effects. No choice is made.
local M={CANCEL={}}
local create,status,yield=coroutine.create,coroutine.status,coroutine.yield
local function resume(thread,...)return require('yieldable_talents').resume(thread,...)end
local frame
local adapted=setmetatable({},{__mode='k'})
local function pack(...)return {n=select('#',...),...}end
function M.active()return frame~=nil end
function M.is_current()return frame and coroutine.running()==frame.co end
function M.waiting()return frame and frame.waiting~=nil end
function M.outcome()return frame and frame.endkind or 'input_cancelled' end
function M.request_stop(reason)if frame then frame.stop_reason=reason;return true end end
function M.note_answer(answer)if frame then frame.cancelled=answer.cancel==true end end
function M.note_control(previous,current,serial)
 if not frame then return end
 assert(previous==frame.current_actor,'unowned native control transition')
 assert(serial>frame.control_serial,'stale native control transition')
 frame.current_actor=current;frame.control_serial=serial;frame.control_changed=true
 frame.endkind='control_changed';frame.stop_after_action=true
end
function M.action_boundary()
 if not frame or not M.is_current() or frame.depth>0 or require('native_control').in_transition() then return end
 assert(game.player==frame.current_actor,'native control changed without a receipt')
 if frame.stop_after_action then error(M.CANCEL,0) end
end
function M.run_action(fn,...)
 if not frame then return fn(...)end
 M.action_boundary();frame.depth=frame.depth+1
 local result=pack(fn(...))
 frame.depth=frame.depth-1;M.action_boundary()
 return unpack(result,1,result.n)
end
function M.resume_native(thread,...)
 if not frame then return resume(thread,...) end
 local result=pack(resume(thread,...))
 if status(thread)=='dead' or not result[1] then frame.results[thread]=result end
 return unpack(result,1,result.n)
end
local function adapt_talent(talent)
 for _,fn in pairs(talent or {})do
  if type(fn)=='function' and not adapted[fn] and debug.getinfo(fn,'S').what=='Lua' then
   local env=getfenv(fn)
   local proxy=setmetatable({resume=M.resume_native},{__index=coroutine})
   setfenv(fn,setmetatable({coroutine=proxy},{__index=env,__newindex=env}));adapted[fn]=true
  end
 end
end
function M.resume_talent(thread,...)
 if not frame then return resume(thread,...) end
 local caller=coroutine.running()
 -- Native skills can build callbacks directly instead of using talentDialog.
 -- Adapt those Lua closures locally, without replacing global coroutine.resume.
 adapt_talent(frame.actor.__talent_running)
 frame.children[caller]=thread
 local result=pack(resume(thread,...))
 if status(thread)=='dead' or not result[1] then frame.results[thread]=result end
 if caller==frame.co and result[1] and require('native_inputs').has_pending() then
  local child=frame.children[thread]
  local completed_now=status(thread)=='dead'
  assert(completed_now or child,'AI input has no original talent owner')
  frame.waiting={wrapper=thread,child=child,completed=completed_now and result or nil}
  yield('native_ai_input')
  local async=frame.waiting.completed
  local completed=async or assert(frame.results[child],'AI talent completion is unknown')
  assert(async or status(child)=='dead' or not completed[1],'AI talent is still running')
  frame.waiting=nil
  if not completed[1] then error(completed[2]) end
  assert(game.player==frame.current_actor,'native AI control transition is unverified')
  -- Let useTalent/forceUseTalent restore their native temporary state first.
  if frame.control_changed then return unpack(completed,1,completed.n) end
  for actor,prior in pairs(frame.party)do
   if (actor.dead and not prior.dead) or (actor._mercenary_down_serial or 0)>prior.serial then
    frame.endkind='input_interrupted';frame.stop_after_action=true
   end
  end
  if frame.stop_after_action then return unpack(completed,1,completed.n) end
  if async then frame.endkind=frame.cancelled and 'input_cancelled' or 'input_resolved';frame.stop_after_action=true end
  if not async and (frame.cancelled or not completed[2]) then
   frame.endkind=frame.cancelled and 'input_cancelled' or 'input_declined';frame.stop_after_action=true
  end
  return unpack(completed,1,completed.n)
 end
 return unpack(result,1,result.n)
end
local function step()
 local result=pack(resume(frame.co))
 if not result[1] then error(result[2]) end
 if status(frame.co)=='dead' then
  local reason=frame.stop_reason or ('native_'..(frame.endkind or 'input_resolved'))
  local value,spent,owner=result[2],frame.actor.energy.value<frame.start_energy,frame.actor;frame=nil;return value,reason,spent,owner
 end
 assert(result[2]=='native_ai_input' and M.waiting() and require('native_inputs').has_pending(),'unclassified AI frame yield')
 frame.prior_paused=game.paused;game.paused=true
 return 'await_input'
end
function M.start(fn,control_serial)
 assert(not frame,'AI frame already active')
 frame={co=create(fn),children={},results={},actor=game.player,current_actor=game.player,control_serial=control_serial or 0,depth=0,start_energy=game.player.energy.value,party={}}
 for _,actor in ipairs(game.party.m_list)do frame.party[actor]={dead=not not actor.dead,serial=actor._mercenary_down_serial or 0}end
 return step()
end
function M.continue()
 assert(M.waiting() and not require('native_inputs').has_pending(),'AI frame cannot continue')
 if not frame.control_changed then game.paused=frame.prior_paused end
 return step()
end
function M.install(talents)
 if M.installed then return end;M.installed=true
 local env=getfenv(talents.useTalent)
 local proxy=setmetatable({resume=M.resume_talent},{__index=coroutine})
 setfenv(talents.useTalent,setmetatable({coroutine=proxy},{__index=env,__newindex=env}))
 local dialog_env=getfenv(talents.talentDialog)
 local dialog_proxy=setmetatable({resume=M.resume_native},{__index=coroutine})
 setfenv(talents.talentDialog,setmetatable({coroutine=dialog_proxy},{__index=dialog_env,__newindex=dialog_env}))
end
return M
