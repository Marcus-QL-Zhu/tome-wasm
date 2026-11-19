// Native item wear/takeoff after the named troll's original whole-table reset.
import {readFile}from'node:fs/promises';
import {resolve}from'node:path';
import {pathToFileURL}from'node:url';
import assert from'node:assert/strict';
const root=resolve('artifacts/tome-content-policy-20261112/release-r2/public');
const {default:createTome}=await import(pathToFileURL(resolve(root,'tome.js')));
const bytes=await readFile(resolve(root,'tome.data'));
const mod=await createTome({wasmBinary:await readFile(resolve(root,'tome.wasm')),getPreloadedPackage:()=>bytes.buffer.slice(bytes.byteOffset,bytes.byteOffset+bytes.byteLength),print:()=>{},printErr:()=>{}});
mod.FS.writeFile('/bundle/headless/native_zone.lua',await readFile('tome_mvp/headless/native_zone.lua'));
mod.FS.writeFile('/bundle/headless/native_name_grammars.lua',await readFile('tome_mvp/headless/native_name_grammars.lua'));
mod.FS.writeFile('/bundle/headless/content_policy.lua',await readFile('tome_mvp/headless/content_policy.lua'));
mod.FS.writeFile('/bundle/headless/worker.lua',`
dofile('/probe.lua')
local json=require('json_validate')
while true do
 local line=protocol_read();if not line then break end
 local req=assert(json.decode(line))
 local ok,result=xpcall(function()
  local state=require('scene').create(7)
  local subclasses=require('engine.Birther').birth_descriptor_def.subclass
  local bulwark_flag=subclasses['Bulwark'].not_on_random_boss
  local policy=require('content_policy');policy.filter_random_boss_talents()
  assert(subclasses['Paradox Mage'].not_on_random_boss==true,'forbidden random class not filtered')
  assert(subclasses['Bulwark'].not_on_random_boss==bulwark_flag,'legal class changed')
  assert(not pcall(policy.check_class,'Paradox Mage'),'explicit forbidden class no longer rejected')
  require('native_zone').install_runtime()
  local NPC=require('mod.class.NPC');local Object=require('mod.class.Object');local D=require('engine.DamageType')
  local actor=NPC.new{name='Damage ledger probe',inc_damage={},body={INVEN=10,BODY=1,FEET=1}}
  local old=Object.new{name='old robe',type='armor',subtype='cloth',slot='BODY',wielder={inc_damage={[D.ARCANE]=15,[D.NATURE]=8,[D.FIRE]=7},combat_armor=3}}
  local fresh=Object.new{name='new boots',type='armor',subtype='feet',slot='FEET',wielder={inc_damage={[D.NATURE]=5}}}
  assert(actor:wearObject(old,true,false,actor.INVEN_BODY,1),'native robe wear failed')
  assert(actor.inc_damage[D.ARCANE]==15 and actor.inc_damage[D.NATURE]==8)
  local original=old.wielder.inc_damage;local id=old.wielded.inc_damage;local armor=actor.combat_armor
  headless_before_troll_damage_clear(actor)
  actor.inc_damage={[D.FIRE]=20}
  assert(old.wielder.inc_damage==original and original[D.ARCANE]==15,'item definition changed')
  assert(next(actor.compute_vals[id])==nil,'old offset not retired')
  assert(actor:wearObject(fresh,true,false,actor.INVEN_FEET,1),'native boots wear failed')
  assert(actor.inc_damage[D.NATURE]==5)
  assert(actor:takeoffObject(actor.INVEN_BODY,1),'native robe takeoff failed')
  assert(actor.inc_damage[D.FIRE]==20 and actor.inc_damage[D.NATURE]==5,'old offset removed new or native bonus')
  assert(actor.combat_armor==armor-3,'unrelated armour offset changed')
  assert(actor:takeoffObject(actor.INVEN_FEET,1),'native boots takeoff failed')
  assert((actor.inc_damage[D.NATURE]or 0)==0 and actor.inc_damage[D.FIRE]==20)
  return json.object({passed=true})
 end,debug.traceback)
 protocol_write(json.encode(json.object({id=req.id,ok=ok,result=ok and result or nil,error=not ok and result or nil}))..'\\n')
end
`);
try{
 const init=mod.cwrap('tome_init','number',[])();assert.equal(init,0,mod.cwrap('tome_result','string',[])());
 const rc=mod.cwrap('tome_request','number',['string'])(JSON.stringify({protocol:'tome-headless-v1',id:1,method:'test',params:{}}));
 const reply=JSON.parse(mod.cwrap('tome_result','string',[])());assert.equal(rc,0,JSON.stringify(reply));assert.deepEqual(reply,{id:1,ok:true,result:{passed:true}});console.log(JSON.stringify(reply));
}finally{mod.cwrap('tome_free',null,[])();}
