// Controlled native death/down fixtures test persistence, not AI win rate.
import {readFile,writeFile,mkdir} from 'node:fs/promises';
import {resolve,dirname} from 'node:path';
import {pathToFileURL} from 'node:url';
import assert from 'node:assert/strict';
const root=resolve(process.argv[2]),output=resolve(process.argv[3]);
const {createKernel}=await import(pathToFileURL(resolve(root,'kernel_runtime.mjs')));
const {BattleSession}=await import(pathToFileURL(resolve(root,'battle_session.mjs')));
const {default:createTome}=await import(pathToFileURL(resolve(root,'tome.js')));
const bytes=await readFile(resolve(root,'tome.data')),wasmBinary=await readFile(resolve(root,'tome.wasm')),identity=JSON.parse(await readFile(resolve(root,'../identity.json'))),logs=[],report={runtime:'real Wasm',fixture_override:true,not_natural_combat:true,cases:[]};
async function make(mode){return createKernel(async options=>{
 const m=await createTome(options),path='/bundle/headless/worker.lua',source=m.FS.readFile(path,{encoding:'utf8'});
 const fixture=`local base_create=scenario.create\nscenario.create=function(...)\nlocal s=base_create(...)\n${mode==='victory'?"for _,a in ipairs(s.enemies)do a:die(s.player)end":mode==='defeat'?"s.game:onTickEnd(function()for _,a in ipairs(s.allies)do a:takeHit(a.max_life*100,s.enemies[1]);assert(require('rescue').is_down(a),'fixture actor still standing')end end)":"s.player:takeHit(s.player.max_life*100,s.enemies[1])"}\nreturn s\nend\n`;
 m.FS.writeFile(path,source.replace("local scenario = require 'scene'","local scenario = require 'scene'\n"+fixture));return m;
},{wasmBinary,getPreloadedPackage:()=>bytes.buffer.slice(bytes.byteOffset,bytes.byteOffset+bytes.byteLength)},{log:(...x)=>{logs.push(x.join(' '));if(logs.length>20)logs.shift();}});}
for(const mode of ['victory','down','defeat']){
 let a,b;
 try{
  a=await make(mode);const s=new BattleSession(a.rpc,identity.build_id+'-fixture-'+mode,23);await s.init();
  if(mode==='victory'||mode==='defeat'){const r=await s.execute('command',{type:'wait',revision:s.bridge.revision});assert.equal(r.status,200);}
  if(mode==='defeat')while(s.bridge.state().capabilities.confirm_down && s.bridge.state().down_events?.length){const v=s.bridge.state();const r=await s.execute('command',{type:'confirm_down',generation:v.generation,event_id:v.down_events[0].id,revision:v.revision});assert.equal(r.status,200);}
  const expected=s.bridge.state();assert.equal(expected.status,mode==='down'?'awaiting_down_confirmation':mode);
  const doc=await s.suspend();b=await make(mode);const restored=await BattleSession.restore(b.rpc,doc.build,doc);assert.deepEqual(restored.bridge.state(),s.bridge.state());
  if(mode==='down'){
   s.suspended=false;let v=s.bridge.state();const confirm={type:'confirm_down',generation:v.generation,event_id:v.down_events[0].id,revision:v.revision};assert.deepEqual(await s.execute('command',confirm),await restored.execute('command',confirm));
   v=s.bridge.state();const target=v.party.find(p=>!p.down).id,takeover={type:'takeover',target:String(target),revision:v.revision};assert.deepEqual(await s.execute('command',takeover),await restored.execute('command',takeover));
  }
  report.cases.push({mode,status:expected.status,restored_identically:true,continued_identically:mode==='down',events:doc.events.length});
 }catch(e){report.error={mode,message:String(e.stack || e)};process.exitCode=1;break;}
 finally{a?.dispose();b?.dispose();}
}
report.passed=report.cases.length===3;report.logs=logs;await mkdir(dirname(output),{recursive:true});await writeFile(output,JSON.stringify(report,null,2));console.log(JSON.stringify({...report,logs:undefined}));
