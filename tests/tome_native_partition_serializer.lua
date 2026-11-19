require 'engine.class'
local F=require 'mod.class.PartitionFixture'
local P=require 'native_save_partition'
local a,b=F.new('hot'),F.new('cold')
local common={value=27};common.self=common;common[common]='table key'
a.shared=common;b.shared=common;b.hot=a;a.func=F.identity;b.func=F.identity;b.func2=F.twice;common[F.identity]='function key'
a.weak=setmetatable({target=b},{__mode='v'});a.weakkeys=setmetatable({[b]={label='held'}},{__mode='k'})
local roots={{owner='hot',root=a},{owner='level:A:1',root=b}}
local data,reg=P.export(roots)
assert(data.parts.hot.root_ref~=data.parts['level:A:1'].root_ref)
assert(data.parts['level:A:1'].strong_refs[data.parts.hot.root_ref])
local coldref=data.parts['level:A:1'].root_ref
local Bundle=require 'native_save_bundle'
local encoded={};for owner,part in pairs(data.parts)do encoded[owner]=Bundle.encode(owner,part,owner=='hot' and data.function_env or nil)end
for owner,part in pairs(encoded)do data.parts[owner]=Bundle.decode(owner,part.payload_base64)end
assert(data.parts.hot.function_env.format=='tome-lua51-environments-v1')
assert(not pcall(Bundle.decode,'wrong-owner',encoded.hot.payload_base64),'owner mixup accepted')
local reads={}
local reader=P.reader(data.index,data.next_ref,function(owner,ref)
 reads[owner]=(reads[owner] or 0)+1;return data.parts[owner].fragments[ref]
end,data.function_env,function(owner,ref)return data.parts[owner].functions[ref]end,function(owner)return data.parts[owner]end)
local hot=reader:load(data.parts.hot.root_ref)
assert(not reads['level:A:1'] and hot.weak.target==nil and next(hot.weakkeys)==nil,'weak ref fetched cold')
assert(hot.shared.self==hot.shared and hot.shared[hot.shared]=='table key')
local cold=reader:load(coldref)
assert(cold.hot==hot and cold.shared==hot.shared and cold.func==hot.func and hot.func(4)==5 and hot.shared[hot.func]=='function key','partition alias split')
assert(hot.weak.target==cold and hot.weakkeys[cold].label=='held','deferred weak relation missing')
assert(cold.func2(4)==8 and getfenv(cold.func2)==getfenv(hot.func),'shared function environment split')
cold.shared.value=49;assert(hot.shared.value==49,'alias mutation not shared')
local second=P.export({{owner='hot',root=hot},{owner='level:A:1',root=cold}},reader:registry(),reader:function_writer())
assert(second.parts.hot.root_ref==data.parts.hot.root_ref and second.parts['level:A:1'].root_ref==coldref,'native refs changed on subsequent save')
assert(#second.function_env.groups==#data.function_env.groups,'shared environment IDs changed')
second=nil
local witness=setmetatable({cold},{__mode='v'});cold=nil
reader:release('level:A:1');collectgarbage('collect');collectgarbage('collect')
assert(witness[1]==nil and hot.weak.target==nil and next(hot.weakkeys)==nil,'cold object held after release')
local again=reader:load(coldref);assert(again.hot==hot and again.shared==hot.shared)
assert(hot.weak.target==again and hot.weakkeys[again].label=='held','weak relation lost after reload')
-- An actual strong edge may demand a real cold object, not a Lua proxy.
local h=F.new('hot-strong');local enemy=F.new('cold-enemy');h.source=enemy;enemy.owner=h
local cross=P.export({{owner='hot',root=h},{owner='level:B:1',root=enemy}})
local cr=P.reader(cross.index,cross.next_ref,function(owner,id)return cross.parts[owner].fragments[id]end,cross.function_env,function(owner,id)return cross.parts[owner].functions[id]end,function(owner)return cross.parts[owner]end)
local hot2=cr:load(cross.parts.hot.root_ref)
assert(hot2.source.owner==hot2 and cr:reads('level:B:1')>0,'strong cross-owner identity lost')

print('NATIVE_PARTITION_SERIALIZER_PASS',data.parts.hot.root_ref,coldref)
