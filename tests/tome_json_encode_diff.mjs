// Differential probe in a disposable Wasm Lua VM; no battle state or package is changed.
import {readFile} from 'node:fs/promises';
import {execFileSync} from 'node:child_process';
import {resolve} from 'node:path';
import {pathToFileURL} from 'node:url';
const root=resolve(process.argv[2]||'artifacts/p2-production-deploy/production-kernel/public');
const original=execFileSync('git',['show','bba3ea9:tome_mvp/headless/json_validate.lua'],{encoding:'utf8'});
const candidate=await readFile(resolve('tome_mvp/headless/json_validate.lua'),'utf8');
const {createKernel}=await import(pathToFileURL(resolve(root,'kernel_runtime.mjs')));
const {default:create}=await import(pathToFileURL(resolve(root,'tome.js')));
const data=await readFile(resolve(root,'tome.data')),wasmBinary=await readFile(resolve(root,'tome.wasm'));
const injection=String.raw`    elseif req.method=='fixture_encode_diff' then
        last_id=id
        local old=dofile('/json-original.lua');local new=dofile('/json-candidate.lua')
        local cases={
          {'scalars',function(m)return m.array({m.null,true,false,0,-4,1/3,1e100})end,true},
          {'escaping-unicode',function(m)return m.object({z='line\nquote"\\\t\1',a='你好 🌍'})end,true},
          {'empty-markers',function(m)return m.array({m.object(),m.array()})end,true},
          {'sorted-keys',function(m)return m.object({z=1,a=2,m=3})end,true},
          {'shared-not-cycle',function(m)local x=m.object({n=1});return m.array({x,x})end,true},
          {'large-nested-base64',function(m)local x=string.rep('ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789+/',55000);return m.object({bundle=m.object({archive=m.array({x,m.object({data=x})})})})end,true},
          {'depth-64',function(m)local x=1;for i=1,64 do x=m.array({x}) end;return x end,true},
          {'depth-65',function(m)local x=1;for i=1,65 do x=m.array({x}) end;return x end,false},
          {'array-bad-key',function(m)return m.array({[1]=1,bad=2})end,false},
          {'array-sparse',function(m)return m.array({[1]=1,[3]=3})end,false},
          {'object-bad-key',function(m)return m.object({[1]=1})end,false},
          {'plain-table',function(m)return {}end,false},
          {'cycle',function(m)local x=m.array();x[1]=x;return x end,false},
          {'nan',function(m)return 0/0 end,false},
          {'inf',function(m)return math.huge end,false},
          {'bad-utf8',function(m)return string.char(255)end,false},
          {'unsupported',function(m)return function()end end,false},
        }
        local results=json.array()
        for _,c in ipairs(cases)do
          local ok1,x=pcall(function()return old.encode(c[2](old))end)
          local ok2,y=pcall(function()return new.encode(c[2](new))end)
          assert(ok1==ok2 and ok1==c[3],'acceptance differs: '..c[1])
          if ok1 then assert(x==y,'output differs: '..c[1]) end
          results[#results+1]=json.object({name=c[1],accepted=ok1,bytes=ok1 and #x or 0})
        end
        local payload=string.rep('ABCDEFGH01234567',131072)
        local function allocated(m)
          local v=payload;for i=1,5 do v=m.object({payload=v}) end
          collectgarbage('collect');collectgarbage('stop');local before=collectgarbage('count')
          local text=m.encode(v);local delta=collectgarbage('count')-before
          assert(#text>#payload);collectgarbage('restart');return delta
        end
        local old_kib=allocated(old);local new_kib=allocated(new)
        reply(id,json.object({cases=results,allocation_sample_kib=json.object({old=old_kib,new=new_kib})}))
`;
let kernel;
try{
 kernel=await createKernel(create,{wasmBinary,getPreloadedPackage:()=>data.buffer.slice(data.byteOffset,data.byteOffset+data.byteLength)},{prepare:m=>{
   const file='/bundle/headless/worker.lua',marker="    elseif req.method=='capabilities' then";
   const worker=m.FS.readFile(file,{encoding:'utf8'});if(!worker.includes(marker))throw Error('missing worker insertion point');
   const load=source=>"assert(loadstring([==["+source+"]==]))()";
   const injected=injection.replace("dofile('/json-original.lua')",()=>load(original)).replace("dofile('/json-candidate.lua')",()=>load(candidate));
   m.FS.writeFile(file,worker.replace(marker,()=>injected+marker));
 }});
 const result=await kernel.rpc('fixture_encode_diff');
 console.log(JSON.stringify(result));
}finally{kernel?.dispose()}
