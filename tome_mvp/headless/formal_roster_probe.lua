dofile('/probe.lua')
local state=require('scene').create(11)
local roster=require 'formal_roster_data'
local builder=require 'formal_roster'
for index,source in ipairs(roster) do
 local actor=builder.create(source,index==1)
 assert(actor.level==source.level and actor.descriptor.subclass==source.subclass and actor.descriptor.sex==source.sex)
 print('FORMAL_ROSTER_PROBE',source.id,actor.__CLASSNAME,actor.descriptor.subclass,actor.level,#source.talents)
end
