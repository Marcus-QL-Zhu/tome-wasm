// Keep a normal rest transition, and bound a native no-progress rest loop.
import {readFile}from'node:fs/promises';
import {resolve}from'node:path';
import {pathToFileURL}from'node:url';
import assert from'node:assert/strict';
const root=resolve('artifacts/tome-content-policy-20261112/release-r2/public');
const {default:createTome}=await import(pathToFileURL(resolve(root,'tome.js')));
const bytes=await readFile(resolve(root,'tome.data'));
const mod=await createTome({wasmBinary:await readFile(resolve(root,'tome.wasm')),getPreloadedPackage:()=>bytes.buffer.slice(bytes.byteOffset,bytes.byteOffset+bytes.byteLength),print:()=>{},printErr:()=>{}});
mod.FS.writeFile('/bundle/headless/player_aioo.lua',await readFile('tome_mvp/headless/player_aioo.lua'));
const baseOnce=await readFile('tome_mvp/headless/aioo_base_once_probe.lua','utf8');
assert.match(baseOnce,/^dofile\('\/probe\.lua'\)\r?\n/);
mod.FS.writeFile('/bundle/headless/base_once.lua',baseOnce.replace(/^dofile\('\/probe\.lua'\)\r?\n/,''));
mod.FS.writeFile('/bundle/headless/worker.lua',`
dofile('/probe.lua')
local json=require('json_validate')
while true do
 local line=protocol_read();if not line then break end
 local req=assert(json.decode(line))
 local ok,result=xpcall(function()
  dofile('/base_once.lua')
  local s=require('scene').create(11)
  for _,enemy in ipairs(s.enemies)do game.level:removeEntity(enemy,true)end
  local p=s.player;p.never_move=1
  p.restCheck=function()return false end
  local controller=require('player_aioo').load_source(headless_aioo_source(),require('mod.class.Player'))
  local energy,turn=p.energy.value,game.turn
  controller.start()
  local result=controller.lifecycle_step(1,true)
  local status,reason=controller.control()
  assert(result=='stopped' and status=='stopped' and reason=='rest_no_progress',tostring(result)..':'..tostring(reason))
  assert(p.energy.value==energy and game.turn==turn,'fake progress added')
  assert(not p.resting and not controller.is_active(),'old rest authorization retained')
  controller.export_state()
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
