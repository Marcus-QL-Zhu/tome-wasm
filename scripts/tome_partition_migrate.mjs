// One-time trusted migration of a server-held native checkpoint into a
// disposable partition candidate. No HTTP client may supply the source archive.
import {readFile,writeFile,stat} from 'node:fs/promises';import {resolve} from 'node:path';import {pathToFileURL} from 'node:url';
import {BattleSession} from '../tome_mvp/wasm/battle_session.mjs';import {buildPartitionCandidate} from './tome_partition_candidate.mjs';
const root=resolve(process.argv[2]),input=resolve(process.argv[3]),output=resolve(process.argv[4]);let kernel;const logs=[];
try{
 if((await stat(input)).size>80*1024*1024)throw Error('partition request envelope exceeds capacity');
 const {archive,scope,version,bootstrap_clock}=JSON.parse(await readFile(input,'utf8')),identity=JSON.parse(await readFile(resolve(root,'../identity.json'),'utf8'));
 if(!Number.isSafeInteger(version) || version<0 || archive?.format!=='tome-native-session-v1' || archive.build!==identity.build_id || scope?.build!==identity.build_id || !Array.isArray(archive.audit))throw Error('invalid trusted migration baseline');
 const {createKernel}=await import(pathToFileURL(resolve(root,'kernel_runtime.mjs'))),{default:create}=await import(pathToFileURL(resolve(root,'tome.js'))),bytes=await readFile(resolve(root,'tome.data')),wasmBinary=await readFile(resolve(root,'tome.wasm'));
 const encounter=identity.encounter_overlay?JSON.parse(await readFile(resolve(root,'encounter.json'),'utf8')):null,install=encounter?(await import(pathToFileURL(resolve(root,'encounter_overlay.mjs')))).installEncounter:null;
 kernel=await createKernel(create,{wasmBinary,getPreloadedPackage:()=>bytes.buffer.slice(bytes.byteOffset,bytes.byteOffset+bytes.byteLength)},{prepare:install?m=>install(m,encounter):undefined,log:(...x)=>{logs.push(x.join(' '));if(logs.length>30)logs.shift();}});
 if(bootstrap_clock!==undefined && (encounter?.purpose!=='party_bootstrap' || archive.base?.checkpoint?.native_boundary!=='campaign_admin' || !Array.isArray(archive.events) || archive.events.length!==0))throw Error('invalid bootstrap migration baseline');
 const session=await BattleSession.restore(kernel.rpc,scope.build,archive);
 const before=bootstrap_clock===undefined?null:await kernel.rpc('dm_inspect',{},session.bridge.generation);
 const enabled=await kernel.rpc('partition_enable',bootstrap_clock===undefined?{}:{bootstrap_migration:{world_id:scope.world_id,campaign_id:scope.campaign_id,world_clock:bootstrap_clock}},session.bridge.generation);
 if(enabled?.accepted!==true || enabled.generation!==session.bridge.generation)throw Error('partition enable rejected');
 // Enabling can physically unload a legacy cached map. Refresh the confirmed
 // native observation before deciding whether a pause action is necessary.
 await session.bridge.observe();
 if(before){const after=await kernel.rpc('dm_inspect',{},session.bridge.generation);for(const key of ['party','rng','next_uid','turn'])if(JSON.stringify(before[key])!==JSON.stringify(after[key]))throw Error('bootstrap migration changed native '+key);}
 session.partitionOnly=true;session.suspended=true;
 const result=await buildPartitionCandidate({session,kernel,scope,prior:null,residentIds:['hot'],operations:[],priorAudit:archive.audit,nextVersion:version+1});
 await writeFile(output,JSON.stringify({ok:true,...result}));
}catch(e){await writeFile(output,JSON.stringify({ok:false,error:String(e.stack||e).slice(0,10000),logs}));process.exitCode=1;}finally{kernel?.dispose();}
