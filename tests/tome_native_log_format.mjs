// Real Lua 5.1 / ToME formatting. No combat, mock formatter, or production save.
import {readFile}from'node:fs/promises';
import {resolve}from'node:path';
import {pathToFileURL}from'node:url';
import assert from'node:assert/strict';
const root=resolve('artifacts/tome-content-policy-20261112/release-r2/public');
const {default:createTome}=await import(pathToFileURL(resolve(root,'tome.js')));
const data=await readFile(resolve(root,'tome.data'));
const mod=await createTome({wasmBinary:await readFile(resolve(root,'tome.wasm')),getPreloadedPackage:()=>data.buffer.slice(data.byteOffset,data.byteOffset+data.byteLength),print:()=>{},printErr:()=>{}});
mod.FS.writeFile('/bundle/headless/scene.lua',await readFile('tome_mvp/headless/scene.lua'));
mod.FS.writeFile('/bundle/headless/worker.lua',`
local json=require('json_validate')
dofile('/probe.lua')
while true do
local line=protocol_read();if not line then break end
local req=assert(json.decode(line))
local ok,result=xpcall(function()
 require('scene').prepare(7,'formal')
 game.log('%s %d%% %s',tstring{'blade'},17,tstring{'shield'})
 assert(game.logNewest()=='blade 17% shield','native formatting mismatch')
 game.log('%s',tstring{'#RED#steel sword#LAST#'})
 assert(game.logNewest()=='#RED#steel sword#LAST#','native colour lost')
 assert(not pcall(game.log,'%s',{}),'plain tables must still fail')
 return json.object({passed=true})
end,debug.traceback)
protocol_write(json.encode(json.object({id=req.id,ok=ok,result=ok and result or nil,error=not ok and result or nil}))..'\\n')
end
`);
try{
 assert.equal(mod.cwrap('tome_init','number',[])(),0);
 const rc=mod.cwrap('tome_request','number',['string'])(JSON.stringify({protocol:'tome-headless-v1',id:1,method:'test',params:{}}));
 const reply=JSON.parse(mod.cwrap('tome_result','string',[])());assert.equal(rc,0,JSON.stringify(reply));assert.deepEqual(reply,{id:1,ok:true,result:{passed:true}});console.log(JSON.stringify(reply));
}finally{mod.cwrap('tome_free',null,[])();}
