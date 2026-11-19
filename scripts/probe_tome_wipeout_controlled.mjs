// Controlled in-memory incapacitation fixture, not a natural encounter.
import {readFile,writeFile,mkdir} from 'node:fs/promises';
import {resolve,dirname} from 'node:path';
import {pathToFileURL} from 'node:url';
import assert from 'node:assert/strict';
const root=resolve(process.argv[2]),output=resolve(process.argv[3]);
const {createKernel}=await import(pathToFileURL(resolve(root,'kernel_runtime.mjs'))),{BattleSession}=await import(pathToFileURL(resolve(root,'battle_session.mjs'))),{installEncounter}=await import(pathToFileURL(resolve(root,'encounter_overlay.mjs'))),{default:createTome}=await import(pathToFileURL(resolve(root,'tome.js')));
const bytes=await readFile(resolve(root,'tome.data')),wasmBinary=await readFile(resolve(root,'tome.wasm')),identity=JSON.parse(await readFile(resolve(root,'../identity.json'))),encounter=JSON.parse(await readFile(resolve(root,'encounter.json'))),logs=[];
const fixture=`local base_create=scenario.create\nscenario.create=function(...)\nlocal s=base_create(...)\ns.game:onTickEnd(function() for _,a in ipairs(s.allies) do a:takeHit(a.max_life*100,s.enemies[1]);assert(require('rescue').is_down(a)) end end)\nreturn s\nend\n`;
let k;const report={fixture_override:true,not_natural_combat:true};
try{
 k=await createKernel(async options=>{const m=await createTome(options);installEncounter(m,encounter);const path='/bundle/headless/worker.lua',source=m.FS.readFile(path,{encoding:'utf8'});m.FS.writeFile(path,source.replace("local scenario = require 'scene'","local scenario = require 'scene'\n"+fixture));return m;},{wasmBinary,getPreloadedPackage:()=>bytes.buffer.slice(bytes.byteOffset,bytes.byteOffset+bytes.byteLength)},{log:(...x)=>{logs.push(x.join(' '));if(logs.length>30)logs.shift();}});
 const s=new BattleSession(k.rpc,identity.build_id+'-controlled',23);await s.init();
 let r=await s.execute('campaign_adopt',{world_id:'w',campaign_id:'c'});assert.equal(r.status,200);
 r=await s.execute('command',{type:'wait',revision:s.bridge.revision});assert.equal(r.status,200);
 const before=s.bridge.state();assert.equal(before.status,'defeat');assert.ok(before.party.every(p=>p.down));
 r=await s.execute('campaign_wipeout',{world_id:'w',world_location:'r'});assert.equal(r.status,200);const after=s.bridge.state();
 assert.equal(after.status,'defeat');assert.equal(after.turn,before.turn);assert.equal(after.party.length,1);assert.equal(after.party[0].hp,1);assert.equal(after.party[0].id,before.party[0].id);
 const reconcile=await s.execute('campaign_reconcile',{world_id:'w',world_location:'r',observation_id:'test'});assert.equal(reconcile.status,200);
 const next=await s.execute('campaign_next',{enemies:[{kind:'native',source:'orc',prototype:'orc warrior',level:50,hp_multiplier:1}],map:{kind:'rooms'}});assert.equal(next.status,200);
 for(let i=0;s.bridge.pending && i<100;i++){const state=s.bridge.state();const step=await s.execute('command',{type:'continue_pending',revision:state.revision});assert.equal(step.status,200);}
 const continued=s.bridge.state();assert.equal(continued.party.length,1);assert.equal(continued.party[0].id,before.party[0].id);
 report.before={turn:before.turn,party:before.party.map(p=>({id:p.id,hp:p.hp,down:p.down}))};report.after={turn:after.turn,party:after.party.map(p=>({id:p.id,hp:p.hp,down:p.down}))};report.next={turn:continued.turn,status:continued.status,hp:continued.party[0].hp,uid:continued.party[0].id};report.transition=r.transition;report.inventory_changes=reconcile.transition;report.passed=true;
}catch(e){report.error=String(e.stack||e);process.exitCode=1;}
finally{k?.dispose();report.logs=logs;await mkdir(dirname(output),{recursive:true});await writeFile(output,JSON.stringify(report,null,2));console.log(JSON.stringify({...report,logs:undefined}));}
