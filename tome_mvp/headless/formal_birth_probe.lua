dofile('/probe.lua')
local state=require('scene').create(11)
local Birther=require 'engine.Birther'
local Player=require 'mod.class.Player'
local p=Player.new{name='Birth probe',faction='allied-kingdoms'}
local definitions=Birther.birth_descriptor_def
local descriptors={}
for _,v in ipairs({{'base','base'},{'world',"Maj'Eyal"},{'difficulty','Normal'},{'permadeath','Adventure'},{'sex','Male'},{'race','Dwarf'},{'subrace','Dwarf'},{'class','Warrior'},{'subclass','Bulwark'}}) do
 local descriptor=assert(definitions[v[1]] and definitions[v[1]][v[2]],v[1]..':'..v[2])
 descriptors[#descriptors+1]=descriptor
end
Birther.apply({actor=p,descriptors=descriptors},true)
assert(p.descriptor.subclass=='Bulwark' and p.descriptor.subrace=='Dwarf')
p:forceLevelup(16)
for stat,value in pairs({str=37,dex=12,con=32,mag=10,wil=16,cun=10}) do
 p:incStat(stat,value-p:getStat(stat,nil,true,true))
end
assert(p.level==16 and p:getStat('str',nil,true,true)==37)
print('FORMAL_NATIVE_BIRTH_PROBE',p.descriptor.subrace,p.descriptor.subclass,p.level,p:getStr(),p:getCon())
