// Private real-Wasm automation probe. No HTTP service, browser, or battle substitute.
import {readFile,writeFile,mkdir} from 'node:fs/promises';
import {resolve,dirname} from 'node:path';
import {pathToFileURL} from 'node:url';
import {EngineBridge} from '../tome_mvp/wasm/engine_bridge.mjs';

const root=resolve(process.argv[2] || 'artifacts/tome-automation-20261112/mvp/public');
const output=resolve(process.argv[3] || 'artifacts/tome-automation-20261112/automation-probe.json');
const retainRest=process.argv.includes('--retain-rest');
const stepArg=process.argv.find(a=>a.startsWith('--sweep-steps='));
const sweepSteps=stepArg ? Number(stepArg.split('=')[1]) : 40;
if(!Number.isInteger(sweepSteps) || sweepSteps<1 || sweepSteps>500)throw Error('sweep steps must be 1..500');
const evidence={runtime:'real WebAssembly under Node',seed:12,stages:{},commands:{},rpc:{},snapshots:[],diagnostics:[],errors:[]};
evidence.retain_rest=retainRest;
let bridge,mod,s,locked=false,seq=0;
const started=performance.now();
function diagnostic(...args){if(evidence.diagnostics.length<100)evidence.diagnostics.push(args.map(String).join(' ').slice(0,500));}
function compact(v){if(!v)return null;return {revision:v.revision,generation:v.generation,turn:v.turn,status:v.status,advance_status:v.advance_status,ai_status:v.ai_status,ai_mode:v.ai_mode,ai_phase:v.ai_phase,ai_epoch:v.ai_epoch,ai_native_turn_count:v.ai_native_turn_count,ai_remaining:v.ai_remaining,ai_stop_reason:v.ai_stop_reason,ai_control_reason:v.ai_control_reason,ai_alert:v.ai_alert,down_events:v.down_events,mission_complete:v.mission_complete,visible_enemies:v.enemies?.length,party:(v.party || []).map(p=>({id:p.id,name:p.name,x:p.x,y:p.y,hp:p.hp,max_hp:p.max_hp,down:p.down}))};}
function snap(stage){evidence.snapshots.push({stage,...compact(s)});if(evidence.snapshots.length>24)evidence.snapshots.shift();}
function check(condition,message){if(!condition)throw Error(message);}
async function command(p){
 const t=performance.now(),r=await bridge.command({...p,revision:s.revision});
 const item=evidence.commands[p.type] ||= {count:0,ms:0};item.count++;item.ms+=performance.now()-t;
 if(r.status!==200){if(r.status>=500)locked=true;throw Error(`${p.type}: ${r.status} ${String(r.body?.error || '').slice(0,250)}`);}
 s=r.body;return s;
}
async function settle(){let count=0;while(s.advance_status==='pending' && count<100){await command({type:'continue_pending'});count++;}check(s.advance_status!=='pending','pending settlement exceeded 100 requests');return count;}
async function runMode(mode,maxSteps,opts={}){
 const out=evidence.stages[opts.name || mode]={mode,steps:0,fight_phase_steps:0,renewals:0,pending_requests:0,phases:[],start:null,end:null,result:'incomplete'};
 if(s.capabilities?.ai_start!==true){out.result='start_unavailable';out.end=compact(s);return out;}
 await command({type:'ai_start',mode,continuous:true,budget:2});out.start=compact(s);
 const epoch=s.control_epoch,nativeEpoch=s.ai_epoch,leader=s.party.find(p=>p.id===s.leader_id),position=leader && [leader.x,leader.y];
 for(let i=0;i<maxSteps && s.ai_status==='running';i++){
  out.pending_requests+=await settle();
  if(s.ai_status!=='running' || ['input','await_input','terminal'].includes(s.advance_status)) break;
  check(s.control_epoch===epoch && s.ai_epoch===nativeEpoch,`${mode}: authorization epoch changed while running`);
  if(s.capabilities?.ai_renew){await command({type:'ai_renew',budget:2,control_epoch:epoch});out.renewals++;}
  if(!s.capabilities?.ai_step)break;
  const beganInFight=s.ai_phase==='fight';
  await command({type:'ai_step',control_epoch:epoch});out.steps++;if(beganInFight)out.fight_phase_steps++;
  out.pending_requests+=await settle();
  if(s.ai_phase && !out.phases.includes(s.ai_phase))out.phases.push(s.ai_phase);
  if(mode==='rest'){
   const current=s.party.find(p=>p.id===s.leader_id);
   check(current && position && current.x===position[0] && current.y===position[1],'rest moved leader');
   check(!['explore','fight'].includes(s.ai_phase),'rest switched to exploration or fighting');
  }
  if(opts.stopOnFight && s.ai_phase==='fight')break;
 }
 out.end=compact(s);out.result=s.ai_status==='running' ? (opts.stopOnFight && s.ai_phase==='fight'?'fight_observed':'step_limit') : (s.ai_stop_reason || s.status || 'stopped');
 snap(opts.name || mode);return out;
}
try {
 const {default:createTome}=await import(pathToFileURL(resolve(root,'tome.js')));
 const data=await readFile(resolve(root,'tome.data'));
 mod=await createTome({wasmBinary:await readFile(resolve(root,'tome.wasm')),getPreloadedPackage:()=>data.buffer.slice(data.byteOffset,data.byteOffset+data.byteLength),print:diagnostic,printErr:diagnostic});
 const init=mod.cwrap('tome_init','number',[]),send=mod.cwrap('tome_request','number',['string']),result=mod.cwrap('tome_result','string',[]);
 check(init()===0,'native initialization failed');
 const rpc=async(method,params={},generation)=>{
  const request={protocol:'tome-headless-v1',id:++seq,method,params};if(generation!=null)request.expected_generation=generation;
  const t=performance.now();let rc,raw;
  try {rc=send(JSON.stringify(request));raw=result();} finally {const m=evidence.rpc[method] ||= {count:0,ms:0};m.count++;m.ms+=performance.now()-t;}
  if(rc!==0)throw Error('native request failed (details withheld)');
  let reply;try{reply=JSON.parse(raw);}catch{throw Error('invalid native response');}
  check(reply.id===seq && typeof reply.ok==='boolean','invalid native response envelope');
  if(reply.ok)return reply.result;
  const err=Error(String(reply.error?.code || 'native error'));err.outcome=reply.error?.outcome;throw err;
 };
 bridge=new EngineBridge(rpc);s=await bridge.init(12);evidence.initialization_ms=performance.now()-started;snap('initial');
 check(s.party?.length===3 && s.map?.length===20 && s.map.every(r=>r.length===20),'unexpected initial fixture');
 await runMode('rest',100);
 if(s.advance_status==='pending')await settle();
 if(s.capabilities?.pause)await command({type:'pause'});
 if(!retainRest){check(s.capabilities?.new_game===true,'new game unavailable after rest');await command({type:'new_game',seed:12});snap('reset');}
 const explore=await runMode('explore',150);
 evidence.explore_visible_enemy_stop=explore.end?.ai_status==='stopped' && explore.end?.visible_enemies>0;
 if(s.capabilities?.ai_start===true){
  check(s.ai_config?.stop_on_rare===false,'Rare stop is enabled by default');
  const sweep=await runMode('sweep',sweepSteps);
  evidence.sweep_fight_observed=sweep.phases.includes('fight');
  evidence.sweep_steps=sweep.steps;
  evidence.sweep_steps_started_in_fight=sweep.fight_phase_steps;
  evidence.sweep_party_health_changes=(sweep.start?.party || []).map(p=>{const end=sweep.end?.party?.find(q=>q.id===p.id);return {id:p.id,name:p.name,start_hp:p.hp,end_hp:end?.hp,changed:end?.hp!==p.hp};});
  // An alert is retried only if the real bounded run produced one.

  if(s.ai_stop_reason==='health_alert' && s.ai_alert?.length && !s.down_events?.length && s.capabilities?.ai_start){
   const before=compact(s),alert=structuredClone(s.ai_alert);const retry=await runMode('sweep',3,{name:'health_retry'});
   const repeated=(retry.end?.ai_alert || []).some(a=>alert.some(old=>a.kind===old.kind && a.actor_id===old.actor_id && a.key===old.key && a.hp===old.hp && a.max_hp===old.max_hp && a.loss===old.loss));
   evidence.health_retry={alert,before,after:retry.end,steps:retry.steps,turn_advanced:retry.end?.turn>before.turn,native_turn_advanced:retry.end?.ai_native_turn_count>before.ai_native_turn_count,unchanged_alert_repeated:repeated};
   check(!(repeated && !(retry.end?.turn>before.turn) && !(retry.end?.ai_native_turn_count>before.ai_native_turn_count)),'same health alert stopped with no observed progression');
  }
 }
 if(!locked && s?.capabilities?.pause)await command({type:'pause'});
 snap('final');
} catch(e) {evidence.errors.push({message:String(e?.message || e).slice(0,500),outcome:e?.outcome || (locked?'unknown':'probe_error'),last_known:compact(s)});}
finally {
 evidence.elapsed_ms=performance.now()-started;
 try {if(mod)mod.cwrap('tome_free',null,[])();}catch(e){evidence.errors.push({message:'module cleanup failed'});}
 await mkdir(dirname(output),{recursive:true});await writeFile(output,JSON.stringify(evidence,null,2));
 console.log(JSON.stringify({output,stages:Object.fromEntries(Object.entries(evidence.stages).map(([k,v])=>[k,v.result])),errors:evidence.errors.length}));
 if(evidence.errors.length)process.exitCode=1;
}
