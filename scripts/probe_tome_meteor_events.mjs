import {readFile,writeFile,mkdir} from 'node:fs/promises';
import {resolve,dirname} from 'node:path';
import {pathToFileURL} from 'node:url';
import assert from 'node:assert/strict';
const root=resolve(process.argv[2]),output=resolve(process.argv[3]);
const {createKernel}=await import(pathToFileURL(resolve(root,'kernel_runtime.mjs')));
const {BattleSession}=await import(pathToFileURL(resolve(root,'battle_session.mjs')));
const {default:createTome}=await import(pathToFileURL(resolve(root,'tome.js')));
const data=await readFile(resolve(root,'tome.data')),wasmBinary=await readFile(resolve(root,'tome.wasm'));
const identity=JSON.parse(await readFile(resolve(root,'../identity.json'),'utf8'));
const fixture=String.raw`
local meteor_probe
local base_create=scenario.create
scenario.create=function(...)
 local s=base_create(...);local p=s.player
 local floor=s.map(p.x,p.y,s.Map.TERRAIN)
 for x=1,18 do for y=1,18 do local g=floor:clone();g.grow='FLOOR';s.map(x,y,s.Map.TERRAIN,g);s.map.lites(x,y,true) end end
 local actors={};for _,a in ipairs(s.allies)do actors[#actors+1]=a;a.invulnerable=1 end;for _,a in ipairs(s.enemies)do actors[#actors+1]=a;a.invulnerable=1 end
 for _,a in ipairs(actors)do s.map:remove(a.x,a.y,s.Map.ACTOR);a.x=nil;a.y=nil end
 for i,a in ipairs(actors)do a:move(2+i,2,true) end
 local center;local emitter=s.map.particleEmitter
 s.map.particleEmitter=function(self,x,y,radius,def,args,...)
  if def=='meteor' then center={x=x,y=y} end
  return emitter(self,x,y,radius,def,args,...)
 end
 local t=p:getTalentFromId(p.T_ANOMALY_METEOR);assert(t.doAction(p,t,true))
 s.map.particleEmitter=emitter;assert(center)
 local target=s.enemies[1];s.map:remove(target.x,target.y,s.Map.ACTOR);target.x=nil;target.y=nil;target:move(center.x,center.y,true)
 target.invulnerable=nil;target.max_life=100000;target.life=100000;target.stun_immune=0;target.combat_physresist=-1000
 -- Retain native scheduler/terrain rules; remove unrelated combat in this fixture.
 for _,a in ipairs(actors)do a.ai='none';a.never_move=true end
 local old=s.map(center.x,center.y,s.Map.TERRAIN)
 meteor_probe=function()
  local g=s.map(center.x,center.y,s.Map.TERRAIN);local count=0
  for x=1,18 do for y=1,18 do if s.map(x,y,s.Map.TERRAIN).subtype=='lava' then count=count+1 end end end
  print('METEOR_PROBE:'..require('json_validate').encode(require('json_validate').object({x=center.x,y=center.y,hp=target.life,stunned=not not target:hasEffect(target.EFF_STUNNED),lava=count,temporary=g.temporary or 0,restored=g==old,crash=p:attr('meteoric_crash') or 0})))
 end
 return s
end
`;
async function make(controlled,readOnly=false){
 const logs=[],samples=[],crashes=[];
 const kernel=await createKernel(async options=>{
  const m=await createTome(options);
  if(controlled){const path='/bundle/headless/worker.lua',source=m.FS.readFile(path,{encoding:'utf8'});m.FS.writeFile(path,source.replace("local scenario = require 'scene'","local scenario = require 'scene'\n"+fixture).replace('local function observe()','local function observe()\n if meteor_probe then meteor_probe() end'));}
  if(readOnly){const path='/bundle/headless/worker.lua',source=m.FS.readFile(path,{encoding:'utf8'});m.FS.writeFile(path,source.replace('local function observe()',"local function observe()\n print('NORMAL_METEOR_PROBE:'..tostring(game.player:attr('meteoric_crash') or 0))"));}
  return m;
 },{wasmBinary,getPreloadedPackage:()=>data.buffer.slice(data.byteOffset,data.byteOffset+data.byteLength)},{log:(...v)=>{const line=v.join(' ');if(line.startsWith('NORMAL_METEOR_PROBE:'))crashes.push(Number(line.slice(20)));if(line.startsWith('METEOR_PROBE:'))samples.push(JSON.parse(line.slice(13)));logs.push(line);if(logs.length>80)logs.shift();}});
 return {kernel,logs,samples,crashes};
}
const report={runtime:'real Wasm',build:identity.build_id,native_meteor_callback_unchanged:true};let a,b,c;
try{
 a=await make(true);const s=new BattleSession(a.kernel.rpc,'meteor-controlled',23);await s.init();
 const start=a.samples.at(-1);assert.equal(start.hp,100000);assert.equal(start.lava,0);assert.equal(s.bridge.state().rule_events.length,1);
 const pending=await s.suspend();assert.equal(a.samples.at(-1).hp,100000);b=await make(true);const r=await BattleSession.restore(b.kernel.rpc,pending.build,pending);s.suspended=false;
 const command={type:'wait',revision:s.bridge.revision};assert.deepEqual(await s.execute('command',command),await r.execute('command',command));
 const hit=a.samples.at(-1);assert.ok(hit.hp<start.hp);assert.equal(hit.stunned,true);assert.ok(hit.lava>0);assert.equal(hit.temporary,8);assert.equal(hit.crash,1);assert.deepEqual(hit,b.samples.at(-1));
 const after=await s.suspend();assert.deepEqual(await r.suspend(),after);r.suspended=false;assert.equal(after.events.at(-2).rule_events[0].phase,'done');s.suspended=false;
 // Both restored and original engines use the ordinary native scheduler to expire lava.
 let commands=0;for(;commands<16 && !a.samples.at(-1).restored;commands++){
  const cmd={type:'wait',revision:s.bridge.revision};assert.deepEqual(await s.execute('command',cmd),await r.execute('command',cmd));
 }
 assert.equal(a.samples.at(-1).restored,true);assert.equal(a.samples.at(-1).lava,0);assert.equal(a.samples.at(-1).crash,1);assert.deepEqual(a.samples,b.samples);
 report.controlled={fixture_override:true,initial:start,impact:hit,final:a.samples.at(-1),wait_commands:commands,pending_replay_identical:true,no_duplicate:true,terrain_expired_natively:true};
 c=await make(false,true);const normal=new BattleSession(c.kernel.rpc,identity.build_id,23);await normal.init();
 const talent=normal.bridge.state().talents.find(t=>t.id==='T_ANOMALY_METEOR');assert.ok(talent?.available,JSON.stringify(talent));
 const result=await normal.execute('command',{type:'talent',talent:'T_ANOMALY_METEOR',revision:normal.bridge.revision});assert.equal(result.status,200,JSON.stringify(result));assert.equal(c.crashes[0],0);assert.equal(c.crashes.at(-1),1);const castView=structuredClone(result.body);const next=await normal.execute('command',{type:'wait',revision:normal.bridge.revision});assert.equal(next.status,200);assert.equal(c.crashes.at(-1),1);
 const archive=await normal.suspend();await writeFile(output+'.archive.json',JSON.stringify({archive}));const d=await make(false);try{const restored=await BattleSession.restore(d.kernel.rpc,archive.build,archive);assert.deepEqual(restored.bridge.state(),normal.bridge.state());}finally{d.kernel.dispose();}
 report.normal_cast={fixture_override:false,read_only_observer:true,turn:castView.turn,events:castView.rule_events,meteor_crash_counts:c.crashes,unmodified_package_replay_identical:true};report.passed=true;
}catch(e){report.error=String(e.stack||e);report.logs=[...(a?.logs||[]),...(c?.logs||[])].slice(-80);report.samples=a?.samples;process.exitCode=1;}
finally{a?.kernel.dispose();b?.kernel.dispose();c?.kernel.dispose();await mkdir(dirname(output),{recursive:true});await writeFile(output,JSON.stringify(report,null,2));console.log(JSON.stringify({...report,error:report.error?.slice(-1800),logs:undefined,samples:undefined}));}
