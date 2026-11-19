-- No ToME graph substitute: identity and ownership invariants only.
local Registry=require 'native_partition_store'
local r=Registry.new(1)
local level={__CLASSNAME='engine.Level'};local actor={__CLASSNAME='mod.class.NPC',uid=271}
local shared={};local fn=function()end
local a=r:pin(level,'floor:A:1');local b=r:assign(actor,'floor:A:1')
local c=r:assign(shared,'floor:A:1');local d=r:assign(fn,'hot')
assert(a=='r:1' and b=='e:271' and c=='r:2' and d=='r:3')
local again,owner=r:assign(shared,'hot');assert(again==c and owner=='floor:A:1')
assert(not pcall(r.pin,r,shared,'hot'))
local index=r:index();local cursor=r:cursor();local q=Registry.new(cursor);q:install_index(index)
local copy={__CLASSNAME='mod.class.NPC',uid=271};assert(q:bind_loaded(b,copy)==b and q:live(b)==copy)
assert(not pcall(q.bind_loaded,q,b,{__CLASSNAME='mod.class.NPC',uid=271}))
assert(not pcall(q.bind_loaded,q,a,{__CLASSNAME='mod.class.NPC',uid=999}))
q:transfer(c,'floor:A:1','hot');assert(q:entry(c).owner=='hot')
assert(not pcall(q.transfer,q,c,'floor:A:1','hot'))
local recruit={__CLASSNAME='mod.class.NPC',uid=272}
local recruit_ref=q:pin(recruit,'hot')
recruit.__CLASSNAME='mod.class.PartyMember'
q:record_party_class(recruit)
assert(q:ref(recruit)==recruit_ref and q:entry(recruit_ref).class=='mod.class.PartyMember')
local reopened=Registry.new(q:cursor());reopened:install_index(q:index())
assert(reopened:bind_loaded(recruit_ref,recruit)==recruit_ref)
recruit.__CLASSNAME='mod.class.NPC'
reopened:record_party_class(recruit)
assert(reopened:entry(recruit_ref).class=='mod.class.NPC')
copy.__CLASSNAME='mod.class.PartyMember'
assert(not pcall(q.record_party_class,q,copy),'cold actor class must stay unchanged')
recruit.__CLASSNAME='mod.class.Player'
assert(not pcall(reopened.record_party_class,reopened,recruit),'unexpected actor class transition')
local witness=setmetatable({level},{__mode='v'});level=nil;collectgarbage('collect');collectgarbage('collect')
assert(witness[1]==nil,'reference registry keeps original level alive')
print('NATIVE_PARTITION_REGISTRY_PASS')
