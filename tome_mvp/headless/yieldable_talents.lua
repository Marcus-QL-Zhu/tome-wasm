-- LuaJIT permits protected talent actions to yield. Lua 5.1 needs a narrow
-- coroutine trampoline. Do not replace global protected calls or C callbacks.
local M={}
local nativeResume=coroutine.resume
-- Lua 5.1 does not inherit instruction hooks across coroutine creation.
-- Carry the caller's bounded hook. Suspended frames retain it while the UI
-- waits; resuming from an unhooked RPC must not erase that saved budget.
function M.resume(thread,...)
 local hook,mask,count=debug.gethook()
 if hook then debug.sethook(thread,hook,mask,count) end
 local function pack(...)return {n=select('#',...),...}end
 local result=pack(nativeResume(thread,...))
 if coroutine.status(thread)=='dead' then debug.sethook(thread) end
 return unpack(result,1,result.n)
end
function M.install()
 if M.installed then return end;M.installed=true
 local talents=require 'engine.interface.ActorTalents'
 local physicalRunning=coroutine.running
 local create,resume,status,yield=coroutine.create,M.resume,coroutine.status,coroutine.yield
 local owner=setmetatable({},{__mode='k'})
 coroutine.running=function()
  local thread=physicalRunning();if thread==nil then return nil end
  return owner[thread] or thread
 end
 local function pack(...)return {n=select('#',...),...}end
 local function protectedTalent(call,handler)
  assert(handler==debug.traceback,'unclassified talent error handler')
  local child=create(call);owner[child]=assert(coroutine.running(),'missing talent coroutine')
  local arguments={n=0}
  while true do
   local result=pack(resume(child,unpack(arguments,1,arguments.n)))
   if not result[1] then
    owner[child]=nil
    if result[2]==require('ai_input_task').CANCEL then return false,result[2] end
    return false,handler(child,result[2],0)
   end
   if status(child)=='dead' then owner[child]=nil;return true,unpack(result,2,result.n)end
   arguments=pack(yield(unpack(result,2,result.n)))
  end
 end
 M.protected=protectedTalent
 local env=getfenv(talents.useTalent)
 setfenv(talents.useTalent,setmetatable({xpcall=protectedTalent},{__index=env,__newindex=env}))
 require('ai_input_task').install(talents)
end
return M
