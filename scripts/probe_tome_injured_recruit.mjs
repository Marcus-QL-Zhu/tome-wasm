// Prepared native wounds/cooldowns isolate recruitment preservation.
import {readFile,writeFile,mkdir} from 'node:fs/promises';
import {resolve,dirname} from 'node:path';
import {pathToFileURL} from 'node:url';
import assert from 'node:assert/strict';
const root=resolve(process.argv[2]),output=resolve(process.argv[3]);
const {createKernel}=await import(pathToFileURL(resolve(root,'kernel_runtime.mjs')));
const {BattleSession}=await import(pathToFileURL(resolve(root,'battle_session.mjs')));
const {default:createTome}=await import(pathToFileURL(resolve(root,'tome.js')));
const bytes=await readFile(resolve(root,'tome.data')),wasmBinary=await readFile(resolve(root,'tome.wasm')),logs=[],kernels=[],report={runtime:'real Wasm',fixture_override:true};
async function make(){const k=await createKernel(async options=>{
 const m=await createTome(options),path='/bundle/headless/worker.lua',source=m.FS.readFile(path,{encoding:'utf8'});
 const fixture=String.raw`
local base_create=scenario.create
scenario.create=function(...)
 local s=base_create(...);local boss=s.enemies[1]
 s.map:remove(boss.x,boss.y,s.Map.ACTOR);boss.x=nil;boss.y=nil
 assert(boss:move(s.player.x+2,s.player.y,true))
 boss.life=boss.max_life*0.01
 boss:setEffect(boss.EFF_CUT,5,{power=1,src=s.player})
 local ids={};for id in pairs(boss.talents)do ids[#ids+1]=id end;table.sort(ids)
 for _,id in ipairs(ids)do local t=boss:getTalentFromId(id);if t.mode=='activated' and (boss:getTalentCooldown(t) or 0)>0 then boss:startTalentCooldown(t);break end end
 s.map.clean_fov=true;s.player:doFOV();return s
end
`;
 m.FS.writeFile(path,source.replace("local scenario = require 'scene'","local scenario = require 'scene'\n"+fixture));return m;
},{wasmBinary,getPreloadedPackage:()=>bytes.buffer.slice(bytes.byteOffset,bytes.byteOffset+bytes.byteLength)},{log:(...x)=>{logs.push(x.join(' '));if(logs.length>15)logs.shift();}});kernels.push(k);return k;}
try{
 const k=await make(),s=new BattleSession(k.rpc,'injured-recruit-fixture-v1',23);await s.init();const before=s.bridge.state(),boss=before.enemies.find(a=>a.hp<a.max_hp*.02);assert.ok(boss);assert.ok(boss.effects.some(e=>e.id==='EFF_CUT'));
 const sheet=await k.rpc('inspect_actor',{target:boss.id},s.bridge.generation);
 const r=await s.execute('dm_transition',{operation:'recruit',operation_id:'injured-boss-joins',target:String(boss.id)});assert.equal(r.status,200);const ally=s.bridge.state().party.at(-1),copy=await k.rpc('inspect_actor',{target:ally.id},s.bridge.generation);
 assert.equal(ally.hp,boss.hp);assert.equal(ally.max_hp,boss.max_hp);assert.equal(ally.x,boss.x);assert.equal(ally.y,boss.y);assert.deepEqual(ally.effects,boss.effects);assert.deepEqual(copy.stats,sheet.stats);assert.deepEqual(copy.equipment,sheet.equipment);assert.deepEqual(copy.combat,sheet.combat);
 const archive=await s.suspend(),other=await make(),restored=await BattleSession.restore(other.rpc,archive.build,archive);assert.deepEqual(restored.bridge.state(),s.bridge.state());report.boss={hp:boss.hp,max_hp:boss.max_hp,effects:boss.effects};report.preserved_hp_position_effects_stats_equipment=true;report.reload_identical=true;report.passed=true;
}catch(e){report.error=String(e.stack || e);process.exitCode=1;}
finally{for(const k of kernels)k.dispose();report.logs=logs;await mkdir(dirname(output),{recursive:true});await writeFile(output,JSON.stringify(report,null,2));console.log(JSON.stringify({...report,logs:undefined}));}
