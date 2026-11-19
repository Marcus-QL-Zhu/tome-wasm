// Frozen scenario, original AIoo policy and original native talent selection.
import {readFile,writeFile,mkdir} from 'node:fs/promises';
import {resolve,dirname} from 'node:path';
import {pathToFileURL} from 'node:url';
import assert from 'node:assert/strict';
const root=resolve(process.argv[2]),output=resolve(process.argv[3]);
const {createKernel}=await import(pathToFileURL(resolve(root,'kernel_runtime.mjs')));
const {BattleSession}=await import(pathToFileURL(resolve(root,'battle_session.mjs')));
const {default:createTome}=await import(pathToFileURL(resolve(root,'tome.js')));
const bytes=await readFile(resolve(root,'tome.data')),wasmBinary=await readFile(resolve(root,'tome.wasm'));
const identity=JSON.parse(await readFile(resolve(root,'../identity.json'))),logs=[];
const make=()=>createKernel(createTome,{wasmBinary,getPreloadedPackage:()=>bytes.buffer.slice(bytes.byteOffset,bytes.byteOffset+bytes.byteLength)},{log:(...v)=>{logs.push(v.join(' '));if(logs.length>50)logs.shift();}});
const report={runtime:'real Wasm',source_overlay:false,fixture_override:false,build:identity.build_id,steps:0};let a,b;
try{
 a=await make();const s=new BattleSession(a.rpc,identity.build_id,23);await s.init();
 const command=async(body)=>{const r=await s.execute('command',{...body,revision:s.bridge.revision});assert.equal(r.status,200,JSON.stringify(r.body).slice(0,400));return r.body;};
 const weights=Object.fromEntries(s.bridge.state().ai_config.talents.map(t=>[t.id,t.id==='T_ARCANE_COMBAT'?10:0]));
 assert.equal(weights.T_ARCANE_COMBAT,10);
 if(!process.argv.includes('--default-policy'))await command({type:'ai_config',stop_on_rare:false,stop_enemy_count:0,talent_weights:weights});
 report.policy=process.argv.includes('--default-policy')?'unchanged default weights':'native relative weights: Arcane Combat 10, other talents 0';
 await command({type:'ai_start',mode:'sweep',continuous:true,budget:100});
 for(let i=0;i<100 && !s.bridge.state().input_request;i++){
  const v=s.bridge.state();if(v.ai_status!=='running')break;
  await command({type:v.advance_status==='pending'?'continue_pending':'ai_step',control_epoch:s.bridge.epoch});report.steps++;
 }
 const pending=s.bridge.state();assert.equal(pending.input_request?.kind,'choice',JSON.stringify(pending).slice(0,500));assert.equal(pending.ai_status,'stopped');
 report.pending={turn:pending.turn,input:pending.input_request,party:pending.party.map(p=>({id:p.id,x:p.x,y:p.y,hp:p.hp})),authorized:s.bridge.authorized};
 const archive=await s.suspend();await writeFile(output.replace(/\.json$/,'.archive.json'),JSON.stringify(archive));
 b=await make();const restored=await BattleSession.restore(b.rpc,identity.build_id,archive);assert.deepEqual(restored.bridge.state(),pending);s.suspended=false;
 const option=pending.input_request.options.find(v=>v.label.includes('Random spells'));assert.ok(option);
 const answer={type:'input_response',input_id:pending.input_request.id,choice:option.id,revision:s.bridge.revision};
 const result=await s.execute('command',answer);assert.deepEqual(await restored.execute('command',answer),result);assert.equal(result.status,200);assert.equal(result.body.ai_status,'stopped');assert.equal(result.body.input_request,null);assert.equal(s.bridge.authorized,false);
 report.resolved={outcome:result.body.last_action,turn:result.body.turn,ai_status:result.body.ai_status,selected_talent_active:result.body.talents.find(t=>t.id==='T_ARCANE_COMBAT')?.active,events:result.body.events};report.pending_replay=true;report.native_policy_selected_menu=true;report.explicit_restart_required=true;report.passed=true;
}catch(e){report.error=String(e.stack||e);report.logs=logs;process.exitCode=1;}
finally{a?.dispose();b?.dispose();await mkdir(dirname(output),{recursive:true});await writeFile(output,JSON.stringify(report,null,2));console.log(JSON.stringify({...report,logs:undefined}));}
