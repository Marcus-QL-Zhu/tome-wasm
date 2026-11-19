// Real native psionic channel, projectiles, movement interruption and replay.
// Controlled geometry and waiting enemies isolate rules from battle survival.
import {readFile,writeFile,mkdir} from 'node:fs/promises';
import {resolve,dirname} from 'node:path';
import {pathToFileURL} from 'node:url';
import assert from 'node:assert/strict';
const root=resolve(process.argv[2]),output=resolve(process.argv[3]);
const {createKernel}=await import(pathToFileURL(resolve(root,'kernel_runtime.mjs')));
const {BattleSession}=await import(pathToFileURL(resolve(root,'battle_session.mjs')));
const {default:createTome}=await import(pathToFileURL(resolve(root,'tome.js')));
const bytes=await readFile(resolve(root,'tome.data')),wasmBinary=await readFile(resolve(root,'tome.wasm')),logs=[];
async function make(){return createKernel(async options=>{
 const m=await createTome(options),path='/bundle/headless/worker.lua',source=m.FS.readFile(path,{encoding:'utf8'});
 const fixture=String.raw`
local base_create=scenario.create
scenario.create=function(...)
 local s=base_create(...);local p=s.player;local floor=s.map(p.x,p.y,s.Map.TERRAIN)
 for x=1,18 do for y=1,18 do s.map(x,y,s.Map.TERRAIN,floor:clone());s.map.lites(x,y,true) end end
 local actors={};for _,a in ipairs(s.allies)do actors[#actors+1]=a end;for _,a in ipairs(s.enemies)do actors[#actors+1]=a end
 for _,a in ipairs(actors)do s.map:remove(a.x,a.y,s.Map.ACTOR);a.x=nil;a.y=nil end
 p:move(4,10,true);s.allies[2]:move(2,10,true);s.allies[3]:move(3,10,true)
 for i,a in ipairs(s.enemies)do a:move(10+i,10,true);a.doAI=function(self)self:useEnergy()end end
 p:learnTalent(p.T_FEEDBACK_POOL,true,1,{no_unlearn=true});p.max_feedback=100;p.feedback=90
 p:learnTalent(p.T_MIND_STORM,true,3,{no_unlearn=true})
 s.map.clean_fov=true;p:doFOV();return s
end
`;
 m.FS.writeFile(path,source.replace("local scenario = require 'scene'","local scenario = require 'scene'\n"+fixture));return m;
},{wasmBinary,getPreloadedPackage:()=>bytes.buffer.slice(bytes.byteOffset,bytes.byteOffset+bytes.byteLength)},{log:(...v)=>{logs.push(v.join(' '));if(logs.length>40)logs.shift();}});}
const report={runtime:'real Wasm',source_overlay:false,fixture_override:true};let a,b;
try{
 a=await make();const s=new BattleSession(a.rpc,'native-channel',23);await s.init();
 const cast=await s.execute('command',{type:'talent',talent:'T_MIND_STORM',revision:s.bridge.revision});assert.equal(cast.status,200);assert.equal(s.bridge.state().talents.find(t=>t.id==='T_MIND_STORM').active,true);
 const archive=await s.suspend();b=await make();const restored=await BattleSession.restore(b.rpc,archive.build,archive);assert.deepEqual(restored.bridge.state(),s.bridge.state());s.suspended=false;
 const before=s.bridge.state(),hp=Object.fromEntries(before.enemies.map(e=>[e.id,e.hp]));
 for(let i=0;i<3;i++){const cmd={type:'wait',revision:s.bridge.revision},r=await s.execute('command',cmd);assert.deepEqual(await restored.execute('command',cmd),r);assert.equal(r.status,200);}
 const waiting=s.bridge.state();assert.equal(waiting.talents.find(t=>t.id==='T_MIND_STORM').active,true);assert.ok(waiting.enemies.some(e=>e.hp<hp[e.id]),'native channel projectiles did not damage an enemy');
 const cmd={type:'move',dx:1,dy:0,revision:s.bridge.revision},move=await s.execute('command',cmd);assert.deepEqual(await restored.execute('command',cmd),move);assert.equal(move.status,200);assert.equal(move.body.party[0].x,before.party[0].x+1);assert.equal(move.body.talents.find(t=>t.id==='T_MIND_STORM').active,false);
 const final=await s.suspend(),c=await make();try{const check=await BattleSession.restore(c.rpc,final.build,final);assert.deepEqual(check.bridge.state(),s.bridge.state());}finally{c.dispose();}
 report.passed=true;report.native_sustain=true;report.native_projectile_damage=true;report.native_move_break=true;report.active_and_interrupted_replay=true;report.turn=move.body.turn;
}catch(e){report.error=String(e.stack||e);report.logs=logs;process.exitCode=1;}
finally{a?.dispose();b?.dispose();await mkdir(dirname(output),{recursive:true});await writeFile(output,JSON.stringify(report,null,2));console.log(JSON.stringify({...report,logs:undefined}));}
