import {readFile,writeFile,mkdir} from 'node:fs/promises';
import {resolve,dirname} from 'node:path';
import {pathToFileURL} from 'node:url';
import assert from 'node:assert/strict';
const root=resolve(process.argv[2]),output=resolve(process.argv[3]);const identity=JSON.parse(await readFile(resolve(root,'../identity.json'),'utf8'));
const {createKernel}=await import(pathToFileURL(resolve(root,'kernel_runtime.mjs')));
const {BattleSession,digest}=await import(pathToFileURL(resolve(root,'battle_session.mjs')));
const bytes=await readFile(resolve(root,'tome.data')),wasmBinary=await readFile(resolve(root,'tome.wasm'));
const {default:createTome}=await import(pathToFileURL(resolve(root,'tome.js')));const kernels=[],report={},logs=[];
async function make(){const kernel=await createKernel(createTome,{wasmBinary,getPreloadedPackage:()=>bytes.buffer.slice(bytes.byteOffset,bytes.byteOffset+bytes.byteLength)},{log:(...x)=>{logs.push(x.join(' '));if(logs.length>30)logs.shift();}});kernels.push(kernel);return kernel;}
try{
 const kernel=await make(),s=new BattleSession(kernel.rpc,identity.build_id,23);await s.init();
 for(let i=0;i<140;i++){const r=await s.execute('command',{type:'wait',revision:s.bridge.revision});assert.equal(r.status,200);}
 let r=await s.execute('command',{type:'ai_start',mode:'explore',budget:500,revision:s.bridge.revision});assert.equal(r.status,200);
 for(let i=0;i<250 && s.bridge.state().ai_status==='running';i++){
  const v=s.bridge.state();r=await s.execute('command',{type:v.advance_status==='pending'?'continue_pending':'ai_step',control_epoch:v.control_epoch,revision:v.revision});assert.equal(r.status,200);
 }
 const archive=await s.suspend();report.events=archive.events.length;assert.ok(report.events>128);
 const k2=await make(),restored=await BattleSession.restore(k2.rpc,identity.build_id,archive);
 assert.equal(await digest(restored.bridge.state()),archive.final);report.complete_reconstruction=true;
 // Continue both independent instances through the same real native actions.
 s.suspended=false;
 for(let i=0;i<5;i++){
  const command={type:'wait',revision:s.bridge.revision};
  const a=await s.execute('command',command),b=await restored.execute('command',command);assert.deepEqual(a,b);
 }
 report.continuation_identical=true;
 const view=restored.bridge.state();assert.ok(view.enemies.length,'no visible recruitment target');
 const boss=view.enemies[0];const before=await restored.execute('inspect',{target:boss.id});
 const recruited=await restored.execute('dm_transition',{operation:'recruit',operation_id:'test-recruit-1',target:String(boss.id)});
 const next=restored.bridge.state();assert.equal(next.party.length,4);const copy=next.party.find(a=>a.dm_source_uid===boss.id) || next.party.find(a=>a.name===boss.name);
 assert.ok(copy);assert.equal(copy.hp,boss.hp);assert.equal(copy.x,boss.x);assert.equal(copy.y,boss.y);assert.notEqual(copy.id,boss.id);
 const after=await restored.execute('inspect',{target:copy.id});assert.deepEqual(before.body.stats,after.body.stats);assert.deepEqual(before.body.equipment,after.body.equipment);assert.equal(after.body.max_hp,before.body.max_hp);
 report.recruit_preserves={hp:copy.hp,position:[copy.x,copy.y],stats:true,equipment:true,source_uid:boss.id,new_uid:copy.id};
 const afterArchive=await restored.suspend(),k3=await make(),final=await BattleSession.restore(k3.rpc,identity.build_id,afterArchive);assert.equal(final.bridge.state().party.length,4);
 report.recruit_survives_reload=true;
 await mkdir(dirname(output),{recursive:true});await writeFile(output.replace(/\.json$/,'.archive.json'),JSON.stringify(archive));await writeFile(output.replace(/\.json$/,'.recruited.json'),JSON.stringify(afterArchive));
 const damaged=structuredClone(archive);damaged.events[0].digest='0'.repeat(64);const k4=await make();await assert.rejects(BattleSession.restore(k4.rpc,identity.build_id,damaged),/diverged/);report.tampering_rejected=true;
 report.passed=true;
}catch(e){report.error=String(e.stack || e);report.logs=logs;process.exitCode=1;}
finally{kernels.forEach(k=>k.dispose());await mkdir(dirname(output),{recursive:true});await writeFile(output,JSON.stringify(report,null,2));console.log(JSON.stringify(report));}
