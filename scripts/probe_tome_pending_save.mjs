import {readFile,writeFile,mkdir} from 'node:fs/promises';
import {resolve,dirname} from 'node:path';
import {pathToFileURL} from 'node:url';
import assert from 'node:assert/strict';
const root=resolve(process.argv[2]),output=resolve(process.argv[3]);
const {createKernel}=await import(pathToFileURL(resolve(root,'kernel_runtime.mjs')));
const {BattleSession}=await import(pathToFileURL(resolve(root,'battle_session.mjs')));
const {default:createTome}=await import(pathToFileURL(resolve(root,'tome.js')));
const bytes=await readFile(resolve(root,'tome.data')),wasmBinary=await readFile(resolve(root,'tome.wasm')),identity=JSON.parse(await readFile(resolve(root,'../identity.json'))),kernels=[],logs=[],report={runtime:'real frozen Wasm',fixture_override:false};
async function make(){const k=await createKernel(createTome,{wasmBinary,getPreloadedPackage:()=>bytes.buffer.slice(bytes.byteOffset,bytes.byteOffset+bytes.byteLength)},{log:(...x)=>{logs.push(x.join(' '));if(logs.length>25)logs.shift();}});kernels.push(k);return k;}
async function command(s,body){const r=await s.execute('command',{...body,revision:s.bridge.revision});assert.equal(r.status,200,JSON.stringify(r));return r;}
try{
 const first=await make(),s=new BattleSession(first.rpc,identity.build_id,23);await s.init();await command(s,{type:'talent',talent:'T_FLAME'});
 assert.equal(s.bridge.state().input_request.kind,'target');const doc=await s.suspend();assert.equal(doc.events.length,1);
 const second=await make(),r=await BattleSession.restore(second.rpc,identity.build_id,doc);assert.deepEqual(r.bridge.state(),s.bridge.state());
 s.suspended=false;assert.deepEqual(await command(s,{type:'input_response',input_id:1,cancel:true}),await command(r,{type:'input_response',input_id:1,cancel:true}));report.target_restored=true;
 await command(s,{type:'talent',talent:'T_ARCANE_COMBAT'});const menu=s.bridge.state().input_request;assert.equal(menu.kind,'choice');const savedMenu=await s.suspend();
 const third=await make(),m=await BattleSession.restore(third.rpc,identity.build_id,savedMenu);assert.deepEqual(m.bridge.state(),s.bridge.state());s.suspended=false;
 const choice=menu.options.find(o=>o.label.includes('Random spells'));assert.ok(choice);assert.deepEqual(await command(s,{type:'input_response',input_id:menu.id,choice:choice.id}),await command(m,{type:'input_response',input_id:menu.id,choice:choice.id}));
 assert.equal(m.bridge.state().talents.find(t=>t.id==='T_ARCANE_COMBAT').active,true);report.menu_restored=true;report.continuation_identical=true;report.passed=true;
 await writeFile(output.replace(/\.json$/,'.archive.json'),JSON.stringify(savedMenu));await writeFile(output.replace(/\.json$/,'.host-input.json'),JSON.stringify({archive:savedMenu,operations:[]}));
}catch(e){report.error=String(e.stack || e);process.exitCode=1;}
finally{for(const k of kernels)k.dispose();report.logs=logs;await mkdir(dirname(output),{recursive:true});await writeFile(output,JSON.stringify(report,null,2));console.log(JSON.stringify({...report,logs:undefined}));}
