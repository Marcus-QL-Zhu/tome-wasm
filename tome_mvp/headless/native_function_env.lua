-- Lua 5.1 does not include a closure's environment or upvalues in lua_dump.
-- These adapters preserve reviewed frozen functions. They are not an archive
-- authentication boundary. The native reader must only open a trusted build.
local json=require 'json_validate'
local M={}
local native_sources={};local source_bytes=0
local max_source=12*1024*1024
local function finite(n)return type(n)=='number' and n==n and n~=math.huge and n~=-math.huge end
local function integer(n)return finite(n) and n==math.floor(n) end
local function fail(s)error('native function environment: '..s,0)end
local function check(v,s)if not v then fail(s)end;return v end
local function name_ok(s)return type(s)=='string' and #s<=200 and s:match('^[%a_][%w_]*$') end
local function supported_path(s)return type(s)=='string' and #s<512 and s:match('^@/[%w_+%-%./]+%.lua$') and not s:find('..',1,true) end

-- Parse only the frozen ABI. A prototype signature omits only its initial
-- source-name field (omitted by Lua if it matches its enclosing prototype).
local function parse(s,visit)
 check(#s<=max_source and s:sub(1,4)=='\27Lua' and s:byte(5)==81 and s:byte(6)==0 and s:byte(7)==1,'unsupported Lua bytecode')
 local I,T,J,N,integral=s:byte(8,12);check(I==4 and (T==4 or T==8) and J==4 and N==8 and integral==0,'unsupported Lua ABI')
 local pos=13
 local function step(n)check(n>=0 and pos+n<=#s+1,'truncated prototype');local p=pos;pos=pos+n;return p end
 local function u(n)local p=step(n);local x=0;for i=n-1,0,-1 do x=x*256+s:byte(p+i)end;return x end
 local function vec()local n=u(I);check(n<=#s,'invalid vector length');return n end
 local function str()local n=u(T);if n==0 then return end;local p=step(n);return s:sub(p,p+n-2)end
 local function proto(depth)
  check(depth<=80,'prototype depth');str();local first=pos;local line,last=u(I),u(I);local nups=u(1);step(3)
  local ng=vec();local code=step(J*ng);local constants={};for i=0,vec()-1 do local t=u(1);if t==1 then step(1) elseif t==3 then step(N) elseif t==4 then constants[i]=str() else check(t==0,'unsupported constant')end end
  local uses={};local omit=false
  for i=0,ng-1 do local a,b,c,d=s:byte(code+4*i,code+4*i+3);local w=a+b*256+c*65536+d*16777216;local op=w%64
   if omit then omit=false elseif op==34 and math.floor(w/16384)%512==0 then omit=true -- extra SETLIST operand
   elseif op==5 or op==7 then local key=constants[math.floor(w/16384)];check(type(key)=='string','invalid global');uses[key]=op==7 and 'write' or uses[key] or 'read' end
  end
  for i=1,vec()do for k,mode in pairs(proto(depth+1))do uses[k]=mode=='write' and 'write' or uses[k] or 'read' end end
  local nline=vec();step(I*nline);for i=1,vec()do str();step(2*I)end;for i=1,vec()do str()end
  visit(depth,line,last,nups,first,pos-1,uses);return uses
 end
 proto(1);check(pos==#s+1,'trailing prototype data')
end

local function frozen(source)
 if native_sources[source] then return native_sources[source] end
 check(supported_path(source),'unregistered source '..tostring(source):sub(1,100))
 local f=loadfile(source:sub(2));check(type(f)=='function','missing frozen source '..source)
 local dump=string.dump(f);local rows={};check(source_bytes+#dump<=64*1024*1024,'frozen source cache limit')
 parse(dump,function(_,line,last,_,first,finish) local k=line..':'..last;rows[k]=rows[k] or {};rows[k][#rows[k]+1]={first,finish}end)
 native_sources[source]={bytes=dump,rows=rows};source_bytes=source_bytes+#dump;return native_sources[source]
end

local function spec(f,allow_upvalues)
 check(type(f)=='function','function required');local info=debug.getinfo(f,'Su')
 check(info.what~='C' and (allow_upvalues or info.nups==0),'unsupported captured upvalues or C function at '..info.short_src..':'..info.linedefined)
 local file=frozen(info.source);local k=info.linedefined..':'..info.lastlinedefined;local candidates=file.rows[k];check(candidates,'unknown prototype '..info.short_src..':'..info.linedefined)
 local bytes=string.dump(f);local globals,ordinal
 parse(bytes,function(depth,_,_,_,a,b,g)if depth~=1 then return end;local signature=bytes:sub(a,b)
  for i,at in ipairs(candidates)do if b-a==at[2]-at[1] and signature==file.bytes:sub(at[1],at[2])then globals=g;ordinal=i;break end end end)
 check(globals,'prototype differs from frozen source '..info.short_src..':'..info.linedefined)
 return globals,info,ordinal
end

local sensitive={getfenv=true,setfenv=true,debug=true,load=true,loadstring=true,loadfile=true,dofile=true,module=true}
-- The native Entity.loadList bootstrap injects this exact registry object
-- into entity definitions. Reuse the initialized registry in the target VM.
local catalog_bindings={DamageType='engine.DamageType'}
-- These two native artifact powers read the setupSummon helper from the
-- live T_SPIDER.action environment. The artifact functions do not inspect
-- their own environments. spec() verifies their full frozen prototypes.
local summon_artifact={
 ['@/data/general/objects/world-artifacts.lua']={[767]=798},
 ['@/data/general/objects/boss-artifacts-maj-eyal.lua']={[681]=712},
}
local function check_summon_catalog()
 local talents=package.loaded['engine.interface.ActorTalents']
 local spider=talents and talents.talents_def and talents.talents_def.T_SPIDER
 local action=spider and spider.action
 check(type(action)=='function','missing T_SPIDER.action')
 local _,a=spec(action)
 check(a.source=='@/data/talents/gifts/summon-utility.lua' and a.linedefined==259 and a.lastlinedefined==320,'unexpected T_SPIDER.action')
 local helper=getfenv(action).setupSummon
 check(type(helper)=='function','missing T_SPIDER.setupSummon')
 local _,h=spec(helper)
 check(h.source=='@/data/talents/gifts/gifts.lua' and h.linedefined==121 and h.lastlinedefined==188,'unexpected T_SPIDER.setupSummon')
end
local function validate_ops(uses,info,env)
 for n in pairs(uses)do
  check(name_ok(n),'invalid global name')
  if sensitive[n] then
   local exact=summon_artifact[info.source]
   check(n=='getfenv' and uses[n]=='read' and exact and exact[info.linedefined]==info.lastlinedefined,'unreviewed environment access '..info.short_src..':'..info.linedefined..':'..n)
   check(rawequal(env.getfenv,_G.getfenv),'unexpected getfenv binding')
   check_summon_catalog()
  end
 end
end

-- engine/class.lua:24 creates one lexical environment proxy per loaded class.
-- It mirrors writes into the actual module table; reconstructing a generic
-- {__index=_G} would lose that identity and its module bindings.
local function module_env(mod,source,env)
 local m=package.loaded[mod];if type(m)~='table' then return nil end
 local function proxy(e)
  local mt=debug.getmetatable(e);local inner=mt and rawget(mt,'__index');local w=mt and rawget(mt,'__newindex')
  return type(inner)=='table' and rawget(inner,'_M')==m and rawget(inner,'_NAME')==mod and type(w)=='function' and debug.getinfo(w,'S').source=='@/engine/class.lua'
 end
 if env then if env==m or proxy(env)then return env end;return nil end
 for _,fn in pairs(m)do if type(fn)=='function' and debug.getinfo(fn,'S').source==source then local e=getfenv(fn);if e==m or proxy(e)then return e end end end
end

function M.catalog_prototype(f)return spec(f,true)end

function M.new_writer(existing,environment_values)
 local ids=setmetatable({},{__mode='k'});local groups=json.array({});local cache=setmetatable({},{__mode='k'});local exposed=0;local environments={}
 if existing then
  check(existing.format=='tome-lua51-environments-v1' and type(existing.groups)=='table','invalid inherited environment manifest')
  for i,g in ipairs(existing.groups)do groups[i]=g end
  for i,env in ipairs(environment_values or {})do assert(groups[i] and type(env)=='table','invalid inherited environment');ids[env]=i;environments[i]=env end
 end
 local writer={}
 function writer:classify(f)
  if cache[f]~=nil then return cache[f] end
  local uses,info=spec(f);local env=getfenv(f);validate_ops(uses,info,env)
  if env==_G then cache[f]=0;return 0 end
  -- Annihilator's native offhand predicate reads only its equipment argument.
  -- The frozen prototype and lack of captured state are already checked by spec.
  if info.source=='@/data-orcs/birth/classes/tinker.lua' and info.linedefined==270 and info.lastlinedefined==273 and not next(uses) then
   cache[f]=0;return 0
  end
  if info.source=='@/data-ashes-urhrok/talents/corruptions/demonic-pact.lua' then
   local talent=require('engine.interface.ActorTalents').talents_def.T_DEMON_SEED
   if talent and rawequal(env,getfenv(talent.createSeed)) then
    -- Per-seed display methods use the native translation and name helpers.
    -- Seed identity, demon state and granted powers stay in the object graph.
    for n,mode in pairs(uses) do
     check(mode=='read' and (n=='tostring' or n=='_t') and rawequal(env[n],_G[n]),'unknown seed display binding '..n)
    end
    cache[f]=0;return 0
   end
  end
  local mod=info.source:sub(3,-5):gsub('/','.')
  if module_env(mod,info.source,env) then
   -- Class modules have engine-defined lookup metatables. Only rebind an
   -- existing, exact named module when this function reads no mutable private
   -- module globals and writes none. Other modules need a reviewed adapter.
   for n,mode in pairs(uses)do check(mode=='read' and rawequal(env[n],_G[n]),'unreviewed module state '..mod..':'..n)end
   local id=ids[env];if not id then id=#groups+1;check(id<=4096,'environment count limit');ids[env]=id;environments[id]=env;groups[id]=json.object({module=mod})end
   cache[f]=id;return id
  end
  local mt=debug.getmetatable(env);local fallback=mt and rawget(mt,'__index') or nil
  check(fallback==nil or fallback==_G,'unknown environment fallback '..info.short_src..':'..info.linedefined)
  check(not mt or rawget(mt,'__newindex')==nil,'unknown environment write hook')
  local id=ids[env];local g=id and groups[id] or json.object({fallback=fallback==_G,locals=json.object({})});local additions={};local count=0
  for n in pairs(uses)do local x=rawget(env,n)
   if x~=nil and g.locals[n]==nil then local t=type(x);local v
    if t=='boolean' or t=='string' or finite(x) then v=json.array({'scalar',x})
    elseif rawequal(rawget(_G,n),x) then v=json.array({'global',n})
    elseif catalog_bindings[n] and t=='table' and rawequal(x,package.loaded[catalog_bindings[n]]) then v=json.array({'catalog',catalog_bindings[n]})
    else fail('cannot rebind private '..n..' ('..t..') at '..info.short_src..':'..info.linedefined) end
    count=count+1;additions[n]=v
   end
  end
  check(exposed+count<=65536,'environment binding limit');if not id then id=#groups+1;check(id<=4096,'environment count limit');groups[id]=g;ids[env]=id;environments[id]=env end
  for n,v in pairs(additions)do g.locals[n]=v end;exposed=exposed+count
  cache[f]=id;return id
 end
 function writer:manifest()return json.object({format='tome-lua51-environments-v1',groups=groups})end
 function writer:environments()return environments end
 return writer
end

function M.new_reader(m)
 check(type(m)=='table' and m.format=='tome-lua51-environments-v1' and type(m.groups)=='table' and #m.groups<=4096,'bad environment manifest')
 local envs={};local nbound=0
 for i,g in ipairs(m.groups)do
  check(type(g)=='table','invalid environment');if g.module then
   check(type(g.module)=='string' and #g.module<=200 and (g.module:match('^mod%.class%.[%w_.]+$') or g.module:match('^engine%.[%w_.]+$')) and not g.module:find('..',1,true) and type(package.loaded[g.module])=='table','unknown live module')
   envs[i]=check(module_env(g.module,'@/'..g.module:gsub('%.','/')..'.lua'),'unknown module environment')
  else
  check(type(g.fallback)=='boolean' and type(g.locals)=='table','invalid environment');local env={}
  if g.fallback then setmetatable(env,{__index=_G})end;envs[i]=env
  for n,tag in pairs(g.locals)do nbound=nbound+1;check(nbound<=65536 and name_ok(n) and type(tag)=='table' and #tag==2,'invalid binding')
   if tag[1]=='global' then check(n==tag[2] and rawget(_G,n)~=nil,'unknown global anchor');env[n]=rawget(_G,n)
   elseif tag[1]=='catalog' then local module=catalog_bindings[n];check(module and module==tag[2] and type(package.loaded[module])=='table','unknown catalog anchor');env[n]=package.loaded[module]
   else local v=tag[2];check(tag[1]=='scalar' and (type(v)=='string' or type(v)=='boolean' or finite(v)),'unsupported private value');env[n]=v end
  end
  end
 end
 local reader={};function reader:bind(f,id)
  check(integer(id) and id>=0 and id<=#envs,'unknown environment id');local uses,info=spec(f);validate_ops(uses,info,id==0 and _G or envs[id])
  if id>0 and m.groups[id].module then local n=m.groups[id].module;check(info.source=='@/'..n:gsub('%.','/')..'.lua','function/module mismatch');for k,mode in pairs(uses)do check(mode=='read' and rawequal(envs[id][k],_G[k]),'changed module state at import')end end
  setfenv(f,id==0 and _G or envs[id]);return f
 end
 function reader:writer()return M.new_writer(m,envs)end
 function reader:rebase(next_manifest,writer)
  local values=assert(writer and writer:environments(),'missing committed environment identities')
  check(type(next_manifest)=='table' and next_manifest.format=='tome-lua51-environments-v1' and type(next_manifest.groups)=='table' and #next_manifest.groups>=#envs,'invalid rebased environments')
  for i,env in ipairs(envs)do check(rawequal(values[i],env),'environment identity changed') end
  for i=1,#next_manifest.groups do check(type(values[i])=='table','missing rebased environment');envs[i]=values[i] end
  m=next_manifest
 end
 return reader
end
return M
