-- Objects registered by the frozen ToME bootstrap. Ordinary instance state is
-- handled by the existing Savefile serializer. No archive supplies executable code.
local M={}
local state
local function fail(message) error('native catalog: '..message,0) end
local function check(ok,message) if not ok then fail(message) end end
local function finite(n) return n==n and n~=math.huge and n~=-math.huge end
local function atom(v)
 local ty=type(v)
 if ty=='number' and finite(v) then return 'n'..string.format('%.17g',v) end
 if ty=='string' then return 's'..v end
 if ty=='boolean' then return v and 'b1' or 'b0' end
 if ty=='nil' then return 'z' end
end
local function framed(s) return #s..':'..s end
local function token(v) local s=atom(v);return s and framed(s) end
local function tables()
 return require('engine.interface.ActorTalents').talents_def,require('engine.interface.ActorResource').resources_def
end
local function ordered(fields)
 local keys={}
 for k in next,fields do
  if not token(k) then return nil end
  keys[#keys+1]=k
 end
 table.sort(keys,function(a,b)return token(a)<token(b) end)
 return keys
end
local function complex(v) return type(v)=='table' or type(v)=='function' end
local function icon(v)
 local mt=type(v)=='table' and debug.getmetatable(v)
 return type(mt)=='table' and rawget(mt,'__index')==package.loaded['engine.Entity']
  and rawget(v,'__CLASSNAME')=='engine.Entity' and rawget(v,'is_talent')==true
end
local libraries={math=true,string=true,table=true,bit=true,util=true,coroutine=true}

function M.freeze()
 if state then return end
 local talents,resources=tables()
 check(type(talents)=='table' and type(resources)=='table' and next(talents) and next(resources),'bootstrap not ready')
 local s={talents=talents,resources=resources,nodes={},envs={},external={},forbidden={},roots={},locations={},count=0,edges=0}
 -- Native modules and global services are explicit external bindings. Their
 -- dynamic world state retains its ordinary native lookup in the new VM.
 local function add(v,tag)
  if type(v)~='table' or rawget(v,'__CLASSNAME') then return end
  if not s.external[v] or tag<s.external[v] then s.external[v]=tag end
 end
 for n,v in next,package.loaded do if type(n)=='string' and complex(v) then
  s.forbidden[v]=true
  if libraries[n] or n:match('^engine%.[%w_.]+$') or n:match('^mod%.class%.[%w_.]+$') then add(v,'module/'..n) end
 end end
 for n,v in next,_G do if type(n)=='string' and complex(v) then
  s.forbidden[v]=true
  if libraries[n] then add(v,'global/'..n) end
 end end
 for _,v in ipairs({_G,package,package.loaded})do s.external[v]=nil;s.forbidden[v]=true end
 for _,name in ipairs({'game','world'})do local v=rawget(_G,name);if complex(v) then s.external[v]=nil;s.forbidden[v]=true end end
 local function register(kind,key,v)
  check(type(v)=='table' and type(key)=='string' and #key<256,'invalid native registration')
  if kind=='talent' then check(rawget(v,'id')==key and rawget(v,'__ATOMIC')==true,'invalid talent '..key)
  else check(rawget(v,'short_name')==key and rawequal(resources[rawget(v,'id')],v),'invalid resource '..key) end
  check(not s.locations[v],'duplicate native definition '..key)
  local root={kind=kind,key=key,value=v}
  s.roots[#s.roots+1]=root;s.locations[v]={root=root,path=''}
 end
 for k,v in next,talents do if type(k)=='string' then register('talent',k,v) end end
 for k,v in next,resources do if type(k)=='string' then register('resource',k,v) end end
 table.sort(s.roots,function(a,b)return a.kind<b.kind or a.kind==b.kind and a.key<b.key end)
 local pending={}
 local function enqueue(v)
  if not complex(v) or s.external[v] or s.forbidden[v] or s.nodes[v] then return end
  s.count=s.count+1;check(s.count<=160000,'bootstrap node budget')
  s.nodes[v]={};pending[#pending+1]=v
 end
 for _,r in ipairs(s.roots) do enqueue(r.value) end
 local i=0
 while i<#pending do
  i=i+1;local v=pending[i];local row=s.nodes[v]
  if type(v)=='table' then
   row.mt=debug.getmetatable(v)
   if not row.mt or icon(v) then
    row.fields={}
    for k,x in next,v do
     s.edges=s.edges+1;check(s.edges<=1400000,'bootstrap edge budget')
     row.fields[k]=x;enqueue(x)
    end
   end
  else
   local inf=debug.getinfo(v,'Su')
   if inf.what~='C' then
    row.env=getfenv(v);row.ups={}
    for j=1,inf.nups do
     local name,x=debug.getupvalue(v,j)
     row.ups[j]={name,x};enqueue(x)
    end
    if row.env~=_G and not s.envs[row.env] then
     local e={fields={},mt=debug.getmetatable(row.env)}
     s.envs[row.env]=e
     e.fallback=e.mt and rawget(e.mt,'__index')
     e.write=e.mt and rawget(e.mt,'__newindex')
     for k,x in next,row.env do
      e.fields[k]=x
      if type(k)=='string' and not rawequal(x,rawget(_G,k)) then enqueue(x) end
     end
    end
   end
  end
 end
 -- Give canonical direct members a deterministic address. This preserves a
 -- separate instance field which points to the same registered child function.
 local queue={}
 for _,r in ipairs(s.roots) do queue[#queue+1]=r.value end
 i=0
 while i<#queue do
  i=i+1;local v=queue[i];local loc=s.locations[v];local row=s.nodes[v]
  if row and row.fields then
   local keys=ordered(row.fields)
   for _,k in ipairs(keys or {}) do
    local x=row.fields[k]
    if complex(x) and s.nodes[x] and not s.locations[x] then
     local p=loc.path..token(k)
     if #p<=1024 then s.locations[x]={root=loc.root,path=p};queue[#queue+1]=x end
    end
   end
  end
 end
 state=s
end

local unsafe={_G=true,getfenv=true,setfenv=true,debug=true,load=true,loadstring=true,loadfile=true,dofile=true,module=true}
local builtin_type=type
local function external_live(tag)
 local where,name=tag:match('^([^/]+)/(.*)$')
 if where=='global' then return name=='_G' and _G or rawget(_G,name) end
 return rawget(package.loaded,name)
end
local function registry_root(s,kind,key)
 local t,r=tables()
 check(rawequal(t,s.talents) and rawequal(r,s.resources),'registry was replaced')
 local value
 if kind=='talent' then
  value=rawget(t,key)
  check(type(value)=='table' and rawget(value,'id')==key and rawget(value,'__ATOMIC')==true,'talent registration changed')
 elseif kind=='resource' then
  value=rawget(r,key)
  check(type(value)=='table' and rawget(value,'short_name')==key and rawequal(rawget(r,rawget(value,'id')),value),'resource registration changed')
 else fail('unknown registry kind') end
 local loc=s.locations[value]
 check(loc and loc.path=='' and loc.root.kind==kind and loc.root.key==key,'registry identity changed')
 return value
end
local function target(s,kind,key,path)
 local v=registry_root(s,kind,key)
 check(type(path)=='string' and #path<=1024,'invalid member path')
 local off=1
 while off<=#path do
  local a,b,n=path:find('(%d+):',off)
  check(a==off and n and #n<=4,'invalid path length')
  n=tonumber(n);check(n>=2 and b+n<=#path,'invalid path token')
  local tag=path:sub(b+1,b+1);local raw=path:sub(b+2,b+n)
  local k
  if tag=='s' then k=raw elseif tag=='n' then k=tonumber(raw)
  elseif tag=='b' then check(raw=='0' or raw=='1','invalid boolean member');k=raw=='1'
  else fail('unknown member type') end
  check(k~=nil and token(k)==path:sub(off,b+n),'noncanonical member')
  local row=s.nodes[v];check(row and row.fields,'member parent unsupported')
  local x=rawget(v,k);check(complex(x) and rawequal(row.fields[k],x),'member changed')
  v=x;off=b+n+1
 end
 return v
end

-- In one VM compare every edge by its ORIGINAL identity. Across VMs use the
-- exact typed graph, ordered keys, alias numbering and frozen prototype ordinal.
local function signature(s,root)
 local out,seen={},{};local used,pieces,nodes=0,0,0
 local function emit(x)
  used=used+#x+12;pieces=pieces+1
  check(used<=512*1024 and pieces<=100000,'definition signature budget')
  out[pieces]=framed(x)
 end
 local inspect=require('native_function_env').catalog_prototype
 check(type(inspect)=='function','frozen prototype verifier missing')
 local visit
 local function binding(v)
  local ext=s.external[v]
  if ext then check(rawequal(external_live(ext),v),'external binding changed');emit('external/'..ext)
  else check(not s.forbidden[v] and (type(v)~='table' or not rawget(v,'__CLASSNAME') or icon(v)),'concrete runtime capture');visit(v) end
 end
 visit=function(v)
  local scalar=atom(v)
  if scalar then emit(scalar);return end
  check(complex(v),'unsupported '..type(v))
  if seen[v] then emit('alias/'..seen[v]);return end
  nodes=nodes+1;check(nodes<=12000,'definition graph budget');seen[v]=nodes
  local row=s.nodes[v];check(row,'unregistered dependency')
  if type(v)=='table' then
   check(row.fields and rawequal(row.mt,debug.getmetatable(v)),'unsupported or changed table metatype')
   emit(row.mt and 'native talent display entity' or 'table')
   if row.mt then check(icon(v),'unsupported class in definition') end
   local keys=ordered(row.fields);check(keys,'unsupported definition key')
   local current=0;for _ in next,v do current=current+1 end
   check(current==#keys,'definition key set changed')
   for _,k in ipairs(keys) do
    local x=rawget(v,k);check(rawequal(x,row.fields[k]),'definition member changed: '..tostring(k))
    emit(atom(k));binding(x)
   end
   emit('/table')
  else
   check(row.ups and rawequal(row.env,getfenv(v)),'unsupported or changed function environment')
   local uses,info,ordinal=inspect(v)
   check(type(ordinal)=='number','frozen prototype ordinal missing')
   emit('function');emit(info.source);emit(tostring(info.linedefined));emit(tostring(info.lastlinedefined));emit(tostring(ordinal))
   for j,p in ipairs(row.ups) do
    local n,x=debug.getupvalue(v,j)
    check(n==p[1] and rawequal(x,p[2]),'changed captured value')
    emit('up/'..n);binding(x)
   end
   local names=ordered(uses);check(names,'invalid global binding')
   for _,n in ipairs(names) do
    local env=row.env
     -- Frozen damDesc shadows the name type and reads only _G.type.
     local damage_type=n=='_G' and info.source=='@/data/talents.lua' and
      info.linedefined==100 and info.lastlinedefined==142 and ordinal==1
     check(uses[n]=='read' and (not unsafe[n] or damage_type),'unsupported global access '..n..' at '..info.source..':'..info.linedefined)
     local e=s.envs[env]
     local raw=rawget(env,n)
     if env~=_G then
      check(e and rawequal(e.mt,debug.getmetatable(env)),'changed loader environment')
      if e.mt then check(rawequal(e.fallback,rawget(e.mt,'__index')) and rawequal(e.write,rawget(e.mt,'__newindex')),'changed loader lookup') end
      check(rawequal(raw,e.fields[n]),'private environment changed: '..n)
     end
     if damage_type then
      local global=raw
      if global==nil and e and e.fallback==_G and not e.write then global=rawget(_G,n) end
      check(rawequal(global,_G) and rawequal(rawget(_G,'type'),builtin_type),'damage type intrinsic changed')
      emit('intrinsic/type')
     else
      emit('read/'..n)
      if env==_G then emit('global-lookup')
      elseif raw==nil then
       check(e.fallback==_G and not e.write,'unknown fallback for '..n);emit('global-lookup')
      elseif rawequal(raw,rawget(_G,n)) and s.external[raw] then emit('named-global/'..n)
      else binding(raw) end
     end
   end
   emit('/function')
  end
 end
 visit(root)
 return table.concat(out)
end

function M.identify(v)
 local s=state;check(s,'baseline missing')
 local loc=s.locations[v];if not loc then return nil end
 local root=loc.root
 check(rawequal(target(s,root.kind,root.key,loc.path),v),'catalog member identity changed')
 local ok,witness=pcall(signature,s,v)
 if not ok then fail(root.kind..'/'..tostring(root.key)..'/'..loc.path..': '..tostring(witness)) end
 return root.kind,root.key,loc.path,witness
end
function M.resolve(kind,key,path,witness)
 local s=state;check(s and type(key)=='string' and #key<=256 and type(witness)=='string' and #witness<=512*1024,'invalid anchor')
 local v=target(s,kind,key,path)
 local loc=s.locations[v]
 check(loc and loc.path==path and loc.root.key==key and loc.root.kind==kind,'not the canonical address')
 check(signature(s,v)==witness,'frozen definition differs')
 return v
end

-- For actor provenance in freshly generated native callbacks. Only complete
-- registered definitions are eligible. This predicate grants no save anchor.
-- It inspects baseline raw fields and captures without interpreting bytecode.
function M.is_catalog_container(v)
 local s=state
 if not s or type(v)~='table' then return false end
 local loc=s.locations[v]
 if not loc or loc.path~='' then return false end
 check(rawequal(registry_root(s,loc.root.kind,loc.root.key),v),'generation container replaced')
 local seen={}
 local count=0
 local function parsed_cache(parent,k,value)
  if parent~=v or loc.root.kind~='talent' then return false end
  if k=='_ai_parsed' or k=='_may_heal' then
   check(value==nil or type(value)=='boolean','invalid native AI cache flag');return true
  end
  if k=='_may_drain_resources' or k=='_may_restore_resources' then
   if value==nil then return true end
   check(type(value)=='table' and not debug.getmetatable(value),'invalid native AI resource cache')
   for name,yes in next,value do
    check(type(name)=='string' and rawget(s.resources,name) and rawget(s.resources,name).short_name==name and yes==true,'invalid native AI resource cache member')
   end
   return true
  end
  return false
 end
 local function same(x)
  if not complex(x) then check(atom(x),'unclassified generation container value');return end
  if seen[x] then return end
  seen[x]=true;count=count+1;check(count<=12000,'generation container budget')
  local ext=s.external[x]
  if ext then
   check(ext~='global/game' and ext~='global/world' and ext~='global/_G' and rawequal(external_live(ext),x),'unclassified gameplay capture')
   return
  end
  check(not s.forbidden[x] and (type(x)~='table' or not rawget(x,'__CLASSNAME') or icon(x)),'concrete runtime capture')
  local row=s.nodes[x];check(row,'new object in native generation container')
  if type(x)=='function' then
   check(row.ups and rawequal(getfenv(x),row.env),'changed generation function')
   for i,p in ipairs(row.ups) do
    local name,value=debug.getupvalue(x,i)
    check(name==p[1] and rawequal(value,p[2]),'generation function capture changed')
    same(value)
   end
  else
   check(row.fields and rawequal(debug.getmetatable(x),row.mt) and (not row.mt or icon(x)),'unknown generation container table')
   for k,value in next,x do
    if not parsed_cache(x,k,value) then
     check(atom(k) and rawequal(value,rawget(row.fields,k)),'generation container member changed')
     same(value)
    end
   end
   for k in next,row.fields do
    check(rawget(x,k)~=nil or parsed_cache(x,k,nil),'generation container member removed')
   end
  end
 end
 same(v)
 return true
end
return M
