import {readFile,writeFile,mkdir} from 'node:fs/promises';
import {resolve,dirname} from 'node:path';
import {pathToFileURL} from 'node:url';
import assert from 'node:assert/strict';
const root=resolve(process.argv[2]),output=resolve(process.argv[3]),overlay=process.argv.includes('--source');
const {createKernel}=await import(pathToFileURL(resolve(root,'kernel_runtime.mjs')));
const {BattleSession}=await import(pathToFileURL(overlay?resolve('tome_mvp/wasm/battle_session.mjs'):resolve(root,'battle_session.mjs')));
const {default:createTome}=await import(pathToFileURL(resolve(root,'tome.js')));
const data=await readFile(resolve(root,'tome.data')),wasmBinary=await readFile(resolve(root,'tome.wasm')),report={runtime:'real Wasm',fixture_override:true,source_overlay:overlay,cases:[]};
async function make(mode){
 const logs=[];const kernel=await createKernel(async options=>{
  const m=await createTome(options);
  if(overlay)for(const name of ['rule_events','headless_visuals','worker','scene','native_actions','native_catalog'])m.FS.writeFile('/bundle/headless/'+name+'.lua',await readFile(resolve('tome_mvp/headless',name+'.lua'),'utf8'));
  const path='/bundle/headless/worker.lua',source=m.FS.readFile(path,{encoding:'utf8'});
  const fixture=String.raw`
local base_create=scenario.create
scenario.create=function(...)
 local s=base_create(...)
 if MODE=='stale_cache' then local events=require('rule_events');local bind=events.bind;events.bind=function(state)bind(state);state.map.__rule_visibility_revision=(state.map.__rule_visibility_revision or 0)+1 end end
 local x,y=s.player.x,s.player.y;if MODE=='hidden' then x,y=0,0 end
 local h=s.map:particleEmitter(x,y,1,'rule_probe',{})
 if MODE=='periodic' then h.on_update=function()end;return s end
 h.on_remove=function()
  print('RULE_PROBE_FIRED:first');s.player:takeHit(1,s.enemies[1])
  if MODE=='down_energy' then
   local ally=s.allies[2];ally:takeHit(ally.max_life*100,s.enemies[1]);assert(require('rescue').is_down(ally))
   local before=ally.energy.value;ally:act();assert(ally.energy.value<before,'down actor did not consume native energy')
  end
  if MODE=='failure' then error('RULE_PROBE_CALLBACK_ERROR') end
 end
 if MODE=='replace' then h.on_remove=nil;h.on_remove=function()print('RULE_PROBE_FIRED:replacement');s.player:takeHit(1,s.enemies[1])end end
 if MODE=='fifo' then local other=s.map:particleEmitter(x,y,1,'rule_probe',{});other.on_remove=function()print('RULE_PROBE_FIRED:second');s.player:takeHit(1,s.enemies[1])end end
 if MODE=='cleanup' then s.map:removeParticleEmitter(h);s.map:removeParticleEmitter(h);s.map:removeParticleEmitters() end
 return s
end
`.replaceAll('MODE',JSON.stringify(mode));
  m.FS.writeFile(path,source.replace("local scenario = require 'scene'","local scenario = require 'scene'\n"+fixture));return m;
 },{wasmBinary,getPreloadedPackage:()=>data.buffer.slice(data.byteOffset,data.byteOffset+data.byteLength)},{log:(...v)=>{logs.push(v.join(' '));if(logs.length>120)logs.shift();}});
 return {kernel,logs};
}
for(const mode of ['pending','fifo','cleanup','replace','hidden','failure','periodic','reset','navigation','down_energy','stale_cache']){
 let first,second;
 try{
  first=await make(mode);const s=new BattleSession(first.kernel.rpc,'rule-event-fixture:'+mode,23);
  if(mode==='periodic'){
   await assert.rejects(s.init());assert.ok(first.logs.some(x=>x.includes('unsupported_rule_bearing_visual_callback:on_update')));report.cases.push({mode,unsupported_rejected:true});continue;
  }
  await s.init();const initial=structuredClone(s.bridge.state());
  assert.equal(initial.rule_events.length,['hidden','stale_cache'].includes(mode)?0:mode==='fifo'?2:1);
  assert.ok(initial.rule_events.every(e=>e.phase==='pending'));assert.ok(!first.logs.some(x=>x.startsWith('RULE_PROBE_FIRED:')));
  await s.execute('inspect',{target:initial.party[0].id});assert.equal(s.bridge.state().party[0].hp,initial.party[0].hp);
  if(mode==='reset'){
   const r=await s.execute('command',{type:'new_game',seed:23,revision:s.bridge.revision});assert.equal(r.status,200);assert.equal(r.body.generation,2);assert.equal(r.body.rule_events.length,1);assert.equal(r.body.rule_events[0].id,1);assert.ok(!first.logs.some(x=>x.startsWith('RULE_PROBE_FIRED:')));report.cases.push({mode,old_queue_discarded:true});continue;
  }
  const archive=await s.suspend();assert.ok(s.bridge.state().rule_events.every(e=>e.phase==='pending'));assert.ok(!first.logs.some(x=>x.startsWith('RULE_PROBE_FIRED:')));
  second=await make(mode);const restored=await BattleSession.restore(second.kernel.rpc,archive.build,archive);assert.deepEqual(restored.bridge.state(),s.bridge.state());s.suspended=false;
  if(mode==='navigation'){
   const start={type:'navigate_start',x:initial.party[0].x+1,y:initial.party[0].y,revision:s.bridge.revision};
   assert.deepEqual(await s.execute('command',start),await restored.execute('command',start));assert.ok(!first.logs.some(x=>x.startsWith('RULE_PROBE_FIRED:')));
  }
  const body={type:mode==='navigation'?'navigate_step':'wait',revision:s.bridge.revision,...(mode==='navigation'?{control_epoch:s.bridge.epoch}:{})};const a=await s.execute('command',body),b=await restored.execute('command',body);assert.deepEqual(a,b);
  if(mode==='failure'){
   assert.equal(a.status,500);assert.equal(s.bridge.locked,true);assert.equal(s.bridge.snapshot.party[0].hp,initial.party[0].hp);const count=first.logs.filter(x=>x.startsWith('RULE_PROBE_FIRED:')).length;assert.equal(count,1);await assert.rejects(s.suspend());assert.equal(first.logs.filter(x=>x.startsWith('RULE_PROBE_FIRED:')).length,1);report.cases.push({mode,unknown_locked:true,no_retry:true});continue;
  }
  assert.equal(a.status,200);assert.equal(a.body.last_action.outcome,'rule_events_settled');assert.equal(a.body.turn,initial.turn);assert.equal(a.body.party[0].x,initial.party[0].x);assert.equal(a.body.party[0].y,initial.party[0].y);assert.ok(a.body.party[0].hp<initial.party[0].hp);
  const fired=first.logs.filter(x=>x.startsWith('RULE_PROBE_FIRED:'));assert.equal(fired.length,mode==='fifo'?2:1);
  if(mode==='fifo')assert.deepEqual(fired,['RULE_PROBE_FIRED:first','RULE_PROBE_FIRED:second']);
  if(mode==='replace')assert.deepEqual(fired,['RULE_PROBE_FIRED:replacement']);
  if(['hidden','stale_cache'].includes(mode))assert.equal(a.body.rule_events.length,0);
  else assert.ok(s.events.at(-1).rule_events.every(e=>e.phase==='done'));
  if(mode==='navigation'){assert.equal(a.body.navigation.status,'stopped');assert.equal(a.body.navigation.stop_reason,'rule_events_settled');}
  if(mode==='down_energy'){assert.ok(a.body.down_events.length>0);report.cases.push({mode,down_consumed_native_energy:true,callback_once:true,command_deferred:true});continue;}
  const follow={type:'wait',revision:s.bridge.revision};assert.deepEqual(await s.execute('command',follow),await restored.execute('command',follow));assert.equal(first.logs.filter(x=>x.startsWith('RULE_PROBE_FIRED:')).length,fired.length);
  report.cases.push({mode,restored_identically:true,settled_once:true,command_deferred:true,continuation_identical:true});
 }catch(e){report.error={mode,message:String(e.stack || e)};report.logs=first?.logs.slice(-25);process.exitCode=1;break;}
 finally{first?.kernel.dispose();second?.kernel.dispose();}
}
report.passed=report.cases.length===11;await mkdir(dirname(output),{recursive:true});await writeFile(output,JSON.stringify(report,null,2));console.log(JSON.stringify({...report,error:report.error,logs:undefined}));
