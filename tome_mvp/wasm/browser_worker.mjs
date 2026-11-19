import createTome from './tome.js';
import {DiagnosticRecorder} from './diagnostics.mjs';
import {createKernel} from './kernel_runtime.mjs';
import {BattleSession,digest} from './battle_session.mjs';
import {restorePartitionCandidate} from './partition_session.mjs';
import {selectPartitions} from './partition_transport.mjs';
import {installEncounter} from './encounter_overlay.mjs';
import {exportBrowserCheckpoint,collectDownFacts} from './browser_checkpoint.mjs';
const recorder=new DiagnosticRecorder('__TOME_BUILD_ID__');
let kernel,session,ready,initializationMs,reportInitialization=true;
let partitionParent,partitionVersion,exportedCheckpoint;
async function start(config={}){
 const began=performance.now();
 let encounter=null;
 if('__TOME_ENCOUNTER_OVERLAY__'==='enabled'){
  const response=await fetch('./encounter.json',{cache:'no-store'});if(!response.ok)throw Error('encounter configuration unavailable');encounter=await response.json();
 }
 kernel=await createKernel(createTome,{}, {
  prepare:encounter?m=>installEncounter(m,encounter):undefined,
  log:(...parts)=>{recorder.log(...parts);if(parts.map(String).join(' ').startsWith('NATIVE_LOCAL_ERROR_REPORT'))recorder.nativeReport(parts.map(String).join(' '));},
  request:(...args)=>recorder.request(...args),observe:s=>recorder.observe(s),fail:(...args)=>recorder.fail(...args),
 });
 if(config.archive?.format==='tome-partition-session-v1'){
  const a=config.archive,p=config.partition,m=p?.manifest,scope={build:recorder.build,world_id:m?.world_id,campaign_id:m?.campaign_id};
  if(!m || p.version!==a.base?.version || a.build!==recorder.build || a.base?.manifest_sha256!==await digest(m) || a.final!==a.base?.envelope?.final || !Array.isArray(a.events) || a.events.length || !Array.isArray(a.audit))throw Error('invalid server partition checkpoint');
  const ids=selectPartitions(m,scope,{kind:'loadout'});
  session=await restorePartitionCandidate(kernel.rpc,recorder.build,a.seed,scope,a.base.envelope,m,ids,p.blobs);
  session.partitionBase=structuredClone(a.base);session.audit=structuredClone(a.audit);
  partitionParent=structuredClone(m);partitionVersion=p.version;
 }else session=config.archive?await BattleSession.restore(kernel.rpc,recorder.build,config.archive):new BattleSession(kernel.rpc,recorder.build,__TOME_ENCOUNTER_SEED__);
 if(!config.archive)await session.init();
 const encounterId=self.location.pathname.match(/\/wasm\/([0-9a-f]{32})\//)?.[1] || null;
 session.combatFacts=config.combat_facts?.encounter_id===encounterId && config.combat_facts?.down_events ? structuredClone(config.combat_facts) : {encounter_id:encounterId,down_events:[],complete:false};
 collectDownFacts(session.combatFacts,session.bridge.state());
 session.suspended=config.suspended===true;initializationMs=performance.now()-began;
}
function view(){const s=session.bridge.state();return {...s,build_id:recorder.build,session_suspended:session.suspended,capabilities:session.suspended?{}:s.capabilities};}
let queue=Promise.resolve();
self.onmessage=({data})=>{queue=queue.then(async()=>{
 const timing={};
 try{
  if(data.path==='/api/diagnostics'){self.postMessage({id:data.id,status:200,body:recorder.export(),timing});return;}
  if(!ready)ready=start(data.path==='/api/bootstrap'?data.body || {}:{});
  await ready;
  if(reportInitialization){timing.initialization_ms=initializationMs;reportInitialization=false;}
  const began=performance.now();let out;
  if(data.path==='/api/state' || data.path==='/api/bootstrap')out={status:200,body:view()};
  else if(data.path==='/api/export_save'){
   collectDownFacts(session.combatFacts,session.bridge.state());
   const archive=await session.suspend();
   if(session.partitionOnly && !exportedCheckpoint)exportedCheckpoint=await exportBrowserCheckpoint(session,partitionParent,partitionVersion);
   out={status:200,body:{archive,view:view(),...(exportedCheckpoint?{snapshot:exportedCheckpoint}:{})}};
  }
  else if(data.path==='/api/adopt_checkpoint'){
   const a=data.body?.archive;
   if(a?.format==='tome-partition-session-v1'){
    if(!session.suspended || !session.partitionOnly || a.build!==recorder.build || a.seed!==session.seed || !a.base || !Array.isArray(a.audit) || !Array.isArray(a.events) || a.events.length || a.base.envelope?.final!==a.final || await digest(session.bridge.state())!==a.final)throw Error('server partition checkpoint does not match local state');
    session.partitionBase=structuredClone(a.base);session.audit=structuredClone(a.audit);session.events=[];out={status:200,body:view()};
    if(data.body.partition?.version!==a.base.version)throw Error('partition parent required after save');
    partitionParent=structuredClone(data.body.partition.manifest);partitionVersion=a.base.version;exportedCheckpoint=null;
   }else{
   if(!session.suspended || a?.format!=='tome-native-session-v1' || a.build!==recorder.build || a.seed!==session.seed || !Array.isArray(a.events) || !Array.isArray(a.audit) || !a.base || await digest(session.bridge.state())!==a.final)throw Error('server checkpoint does not match local state');
   session.nativeBase=structuredClone(a.base);session.audit=structuredClone(a.audit);session.events=structuredClone(a.events);out={status:200,body:view()};
   }
  }
  else if(data.path==='/api/continue_session'){session.suspended=false;exportedCheckpoint=null;out={status:200,body:view()};}
  else if(data.path==='/api/loot_preview'){
   await session.settle();
   const preview=await kernel.rpc('loot_preview',{},session.bridge.generation);
   out={status:200,body:{...preview,view:view()}};
  }
  else if(session.suspended)out={status:409,body:{error:'战局已暂挂，等待宿主恢复'}};
  else if(data.path==='/api/inspect')out=await session.execute('inspect',data.body);
  else if(data.path==='/api/command')out=await session.execute('command',data.body);
  else out={status:404,body:{error:'unknown path'}};
  if(out.status>=500)recorder.fail('bridge_failure',out.body?.error || 'unknown');
  collectDownFacts(session.combatFacts,session.bridge.state());
  if(data.path==='/api/command' && out.status===200)out.body=view();
  timing.engine_ms=performance.now()-began;self.postMessage({id:data.id,...out,timing});
 }catch(e){recorder.fail('worker_failure',e.stack || e);self.postMessage({id:data.id,status:500,body:{error:'Wasm 内核不可用，战斗状态未知'},timing});}
});};
