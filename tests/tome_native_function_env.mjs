// Runs against real Lua 5.1 in two isolated Wasm instances. A candidate bundle
// is an explicit input; the new module alone is overlaid on the frozen build.
import assert from 'node:assert/strict';import {readFile} from 'node:fs/promises';import {resolve} from 'node:path';import {pathToFileURL} from 'node:url';
const base=resolve(process.argv[2]||'artifacts/native-save-core-20261115/candidate7/public');
const [{default:create},data,wasmBinary,mod]=await Promise.all([import(pathToFileURL(resolve(base,'tome.js'))),readFile(resolve(base,'tome.data')),readFile(resolve(base,'tome.wasm')),readFile('tome_mvp/headless/native_function_env.lua','utf8')]);
const fixture=`return {
 increment=function() shared_counter=shared_counter+1;return shared_counter end,
 read=function()return shared_counter end,
 nested=function()return function()return private_switch end end,
 sensitive=function()return getfenv(1)end,
 closure=(function() local n=1;return function()return n end end)(),
 private_table=function()return private_table end,
 registry=function()return DamageType end,
}`;
async function vm(){const m=await create({wasmBinary,getPreloadedPackage:()=>data.buffer.slice(data.byteOffset,data.byteOffset+data.byteLength),print:()=>{},printErr:()=>{}});m.FS.writeFile('/bundle/headless/native_function_env.lua',mod);m.FS.writeFile('/bundle/headless/function_env_fixture.lua',fixture);
 const root='/bundle/headless/worker.lua';let worker=m.FS.readFile(root,{encoding:'utf8'});const insert="    elseif req.method=='save' then";assert(worker.includes(insert));worker=worker.replace(insert,`    elseif req.method=='consult_env' then
     local ok,ans=xpcall(function()
      local env=require 'native_function_env';local mime=assert(_G.mime);local j=require 'json_validate';local f=dofile('/function_env_fixture.lua');local DamageType=require 'engine.DamageType'
      if req.params.manifest then
       local r=env.new_reader(req.params.manifest);local function load(n)local row=req.params.functions[n];return r:bind(assert(loadstring(mime.unb64(row[1],nil))),row[2])end
       local a,b,ind,nested=load('increment'),load('read'),load('independent'),load('nested');assert(getfenv(a)==getfenv(b) and getfenv(a)~=getfenv(ind));assert(a()==10 and b()==10 and ind()==42 and nested()()==false and _G.shared_counter==nil);assert(rawequal(load('registry')(),DamageType));assert(not pcall(r.bind,r,f.read,9001));local bad=req.params.manifest;bad.groups[1].locals.DamageType=j.array({'catalog','engine.Entity'});assert(not pcall(env.new_reader,bad));return {result='restored shared private envs, registry identity, nested reads and isolated writer'}
      end
      local shared=setmetatable({shared_counter=9,private_switch=false},{__index=_G});local independent=setmetatable({shared_counter=42},{__index=_G});local f2=dofile('/function_env_fixture.lua');local w=env.new_writer();local defs=j.object({});local function put(k,v,e)setfenv(v,e);defs[k]=j.array({mime.b64(string.dump(v),nil),w:classify(v)})end
      shared.DamageType=DamageType;put('increment',f.increment,shared);put('read',f.read,shared);put('nested',f.nested,shared);put('independent',f2.read,independent);put('registry',f.registry,shared);assert(defs.read[2]==defs.increment[2] and defs.read[2]~=defs.independent[2]);
      assert(not pcall(w.classify,w,f.closure));assert(not pcall(w.classify,w,f.sensitive));assert(not pcall(w.classify,w,print));local forged=assert(loadstring('return function() return 987654 end','@/function_env_fixture.lua'))();assert(not pcall(w.classify,w,forged));
      setfenv(f.private_table,setmetatable({private_table={}},{__index=_G}));assert(not pcall(w.classify,w,f.private_table));local f3=dofile('/function_env_fixture.lua');setfenv(f3.read,setmetatable({}, {__index=function() return 1 end}));assert(not pcall(w.classify,w,f3.read))
      local f4=dofile('/function_env_fixture.lua');setfenv(f4.registry,setmetatable({DamageType={}},{__index=_G}));assert(not pcall(w.classify,w,f4.registry));return {manifest=w:manifest(),functions=defs,negative=7}
     end,debug.traceback);reply(req.id,ok and ans or {failure=tostring(ans)})
    elseif req.method=='save' then`);m.FS.writeFile(root,worker);const init=m.cwrap('tome_init','number',[]),rq=m.cwrap('tome_request','number',['string']),rs=m.cwrap('tome_result','string',[]);assert.equal(init(),0,rs());return p=>{assert.equal(rq(JSON.stringify({protocol:'tome-headless-v1',id:1,method:'consult_env',params:p})),0);const obj=JSON.parse(rs());assert(obj.ok);assert(!obj.result.failure,obj.result.failure);return obj.result};}
const a=await vm(),b=await vm(),saved=a({});assert.equal(saved.negative,7);assert.equal(saved.manifest.groups.length,2);console.log(JSON.stringify({negative:saved.negative,...b(saved)}));
