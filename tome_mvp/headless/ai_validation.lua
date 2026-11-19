dofile('/probe.lua')
local s=require('scene').create(11)
local p=s.player
local old_set,old_get=rawget(p,'setTarget'),rawget(p,'getTarget')
p.setTarget=require('mod.class.interface.ActorAI').setTarget
p.getTarget=require('engine.interface.ActorAI').getTarget
p:doFOV(); p.energy.used=false
local before=p.energy.value
local ok,err=xpcall(function() p:runAI('improved_tactical') end,debug.traceback)
p.setTarget,p.getTarget=old_set,old_get
if not ok then error(err) end
assert(p.energy.value<before,'native AI did not use energy')
print('NATIVE_PLAYER_AI_PASS',before,p.energy.value)
