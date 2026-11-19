// Experimental server-only validator. Input is assembled by the trusted Python
// host from its locked battle version, never accepted as an HTTP client body.
import {readFile,writeFile,stat} from 'node:fs/promises';
import {resolve} from 'node:path';
import {pathToFileURL} from 'node:url';
import {selectPartitions} from '../tome_mvp/wasm/partition_transport.mjs';
import {restorePartitionCandidate} from '../tome_mvp/wasm/partition_session_host.mjs';
import {buildPartitionCandidate} from './tome_partition_candidate.mjs';
import {executeNativeOperations} from './tome_validate_operations.mjs';
import {digest,canonical} from '../tome_mvp/wasm/battle_session.mjs';
const root=resolve(process.argv[2]),input=resolve(process.argv[3]),output=resolve(process.argv[4]);let kernel;const logs=[];
try{
 if((await stat(input)).size>80*1024*1024)throw Error('partition request envelope exceeds capacity');
 const req=JSON.parse(await readFile(input,'utf8'));
 const {scope,archive,manifest,blobs,selection,version,operations,delta_events}=req;
 const identity=JSON.parse(await readFile(resolve(root,'../identity.json'),'utf8'));
 if(scope?.build!==identity.build_id || archive?.format!=='tome-partition-session-v1' || archive.build!==scope.build || archive.base?.version!==version || archive.base?.manifest_sha256!==await digest(manifest) || archive.final!==archive.base.envelope?.final || !Array.isArray(archive.audit) || !Array.isArray(archive.events) || archive.events.length || !Array.isArray(operations) || !Array.isArray(delta_events) || delta_events.length>200000)throw Error('invalid trusted partition baseline');
 const ids=selectPartitions(manifest,scope,selection);
 if(!blobs || canonical(Object.keys(blobs).sort())!==canonical([...ids].sort()))throw Error('authorized partition set mismatch');
 const {createKernel}=await import(pathToFileURL(resolve(root,'kernel_runtime.mjs'))),{default:create}=await import(pathToFileURL(resolve(root,'tome.js')));
 const bytes=await readFile(resolve(root,'tome.data')),wasmBinary=await readFile(resolve(root,'tome.wasm'));
 const encounter=identity.encounter_overlay?JSON.parse(await readFile(resolve(root,'encounter.json'),'utf8')):null;
 const install=encounter?(await import(pathToFileURL(resolve(root,'encounter_overlay.mjs')))).installEncounter:null;
 kernel=await createKernel(create,{wasmBinary,getPreloadedPackage:()=>bytes.buffer.slice(bytes.byteOffset,bytes.byteOffset+bytes.byteLength)},{prepare:install?m=>install(m,encounter):undefined,log:(...x)=>{logs.push(x.join(' '));if(logs.length>30)logs.shift();}});
 const session=await restorePartitionCandidate(kernel.rpc,scope.build,archive.seed,scope,archive.base.envelope,manifest,ids,blobs);session.suspended=false;
 for(const event of delta_events){
  if(!event || !['command','inspect'].includes(event.kind))throw Error('unauthorized incremental event');
  await session.execute(event.kind,event.body);const actual=session.events.at(-1);
  if(actual.digest!==event.digest || canonical(actual.rule_events || [])!==canonical(event.rule_events || []))throw Error('incremental event diverged');
 }
 if(req.expected_final!==undefined && (typeof req.expected_final!=='string' || await digest(session.bridge.state())!==req.expected_final))throw Error('incremental final state mismatch');
 if(operations.length && operations.every(op=>op.operation==='scene_query')){
  if(delta_events.length)throw Error('read-only query cannot advance events');
  await writeFile(output,JSON.stringify({ok:true,query_results:await executeNativeOperations(session,kernel,{operations})}));
 }else{
 const result=await buildPartitionCandidate({session,kernel,scope,prior:manifest,residentIds:ids,operations,priorAudit:archive.audit,nextVersion:version+1});
 await writeFile(output,JSON.stringify({ok:true,...result}));
 }
}catch(e){await writeFile(output,JSON.stringify({ok:false,error:String(e.stack||e).slice(0,10000),logs}));process.exitCode=1;}
finally{kernel?.dispose();}
