// Bounded real-Wasm driver. A non-defeat result is retained, never coerced.
import {readFile,writeFile,mkdir} from 'node:fs/promises';
import {resolve,dirname} from 'node:path';
import {pathToFileURL} from 'node:url';
const root=resolve(process.argv[2]), output=resolve(process.argv[3]);
const {createKernel}=await import(pathToFileURL(resolve(root,'kernel_runtime.mjs')));
const {BattleSession}=await import(pathToFileURL(resolve(root,'battle_session.mjs')));
const {default:createTome}=await import(pathToFileURL(resolve(root,'tome.js')));
const identity=JSON.parse(await readFile(resolve(root,'../identity.json'))), bytes=await readFile(resolve(root,'tome.data')), wasmBinary=await readFile(resolve(root,'tome.wasm'));
const encounter=identity.encounter_overlay?JSON.parse(await readFile(resolve(root,'encounter.json'))):null;
const install=encounter?(await import(pathToFileURL(resolve(root,'encounter_overlay.mjs')))).installEncounter:null;
const kernels=[],logs=[];const report={fixture_override:process.argv.includes('--fixture'),events:0};
async function kernel(){const k=await createKernel(createTome,{wasmBinary,getPreloadedPackage:()=>bytes.buffer.slice(bytes.byteOffset,bytes.byteOffset+bytes.byteLength)},{prepare:encounter?m=>install(m,encounter):undefined,log:(...args)=>{logs.push(args.join(' '));if(logs.length>60)logs.shift();}});kernels.push(k);return k;}
try{
 await mkdir(dirname(output),{recursive:true});
 let k=await kernel(),s;let initial;
 if(process.argv[5] && !process.argv[5].startsWith('--'))initial=JSON.parse(await readFile(resolve(process.argv[5])));
 else{s=new BattleSession(k.rpc,identity.build_id,Number(process.argv[4]||23));await s.init();initial=await s.suspend();}
 await writeFile(output+'.before.archive.json',JSON.stringify(initial));
 k=await kernel();s=await BattleSession.restore(k.rpc,identity.build_id,initial);
 for(let i=0;i<2400;i++){
  const v=s.bridge.state();if(['victory','defeat'].includes(v.status))break;
  let action;
  if(v.down_events?.length)action={type:'confirm_down',generation:v.generation,event_id:v.down_events[0].id};
  else if(v.advance_status==='pending')action={type:'continue_pending'};
  else if(v.party.find(p=>p.id===v.control_actor_id)?.down && v.capabilities.takeover){const target=v.party.find(p=>!p.down&&!p.dead);if(!target)throw Error('no standing target');action={type:'takeover',target:String(target.id)};}
  else if(process.argv[6]==='wait' && v.capabilities.wait)action={type:'wait'};
  else if(v.ai_status==='running')action=v.capabilities.ai_renew?{type:'ai_renew',budget:500,control_epoch:v.control_epoch}:v.ai_remaining>0&&v.capabilities.ai_step?{type:'ai_step',control_epoch:v.control_epoch}:{type:'pause'};
  else if(v.capabilities.ai_start)action={type:'ai_start',mode:'sweep',budget:500,continuous:true};
  else if(v.capabilities.wait)action={type:'wait'};
  else throw Error('driver stopped: '+v.status+' / '+v.ai_stop_reason);
  const result=await s.execute('command',{...action,revision:v.revision});if(result.status!==200)throw Error('command rejected: '+JSON.stringify(result));
 }
 const last=s.bridge.state();report.final={status:last.status,turn:last.turn,party:last.party.map(p=>({id:p.id,hp:p.hp,down:p.down}))};report.events=s.events.length;
 if(last.status==='defeat'){
  const archive=await s.suspend();await writeFile(output+'.defeat.archive.json',JSON.stringify(archive));
  const replay=await kernel();await BattleSession.restore(replay.rpc,identity.build_id,archive);report.terminal_replay_verified=true;
 }else report.incomplete=true;
}catch(e){report.error=String(e.stack||e);process.exitCode=1;}
finally{for(const k of kernels)k.dispose();report.logs=logs;await mkdir(dirname(output),{recursive:true});await writeFile(output+'.json',JSON.stringify(report,null,2));console.log(JSON.stringify({...report,logs:undefined}));}
