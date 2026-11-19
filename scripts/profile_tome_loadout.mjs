// Diagnostic harness only. Uses the unchanged frozen modules in an isolated Node process.
import {readFile,writeFile} from 'node:fs/promises';
import {resolve} from 'node:path';
import {pathToFileURL} from 'node:url';
import {performance} from 'node:perf_hooks';
const began=performance.now(),cpuBegan=process.cpuUsage();
const root=resolve(process.argv[2]),input=resolve(process.argv[3]),output=resolve(process.argv[4]);
const profile={stages:{},rpc:[],executions:[],native_calls:[],events:0};let phase='setup';
async function timed(name,fn){const start=performance.now(),cpu=process.cpuUsage();try{return await fn();}finally{const used=process.cpuUsage(cpu);profile.stages[name]={wall_ms:performance.now()-start,cpu_ms:(used.user+used.system)/1000};}}
let kernel;
try{
 const request=await timed('input_read_parse',async()=>JSON.parse(await readFile(input,'utf8')));
 const identity=JSON.parse(await readFile(resolve(root,'../identity.json'),'utf8'));
 if(!Array.isArray(request.archive?.events)||request.archive.events.length>10000)throw Error('diagnostic event limit');
 profile.events=request.archive.events.length;profile.operation_kinds=request.operations.map(x=>x.operation);
 const {createKernel}=await timed('kernel_module_import',()=>import(pathToFileURL(resolve(root,'kernel_runtime.mjs'))));
 const {BattleSession}=await timed('session_module_import',()=>import(pathToFileURL(resolve(root,'battle_session.mjs'))));
 const {default:createTome}=await timed('tome_js_import',()=>import(pathToFileURL(resolve(root,'tome.js'))));
 const bytes=await timed('tome_data_read',()=>readFile(resolve(root,'tome.data')));
 const wasm=await timed('tome_wasm_read',()=>readFile(resolve(root,'tome.wasm')));
 const encounter=identity.encounter_overlay?JSON.parse(await readFile(resolve(root,'encounter.json'),'utf8')):null;
 const installEncounter=encounter?(await import(pathToFileURL(resolve(root,'encounter_overlay.mjs')))).installEncounter:null;
 profile.data_bytes=bytes.byteLength;profile.wasm_bytes=wasm.byteLength;
 const measuredTome=async options=>{
  const mod=await timed('emscripten_createTome',()=>createTome(options));
  const original=mod.cwrap;
  mod.cwrap=function(name,...args){const fn=original.call(this,name,...args);if(!['tome_init','tome_request','tome_result','tome_free'].includes(name))return fn;
   return(...callArgs)=>{let method=null;if(name==='tome_request')method=JSON.parse(callArgs[0]).method;const start=performance.now(),cpu=process.cpuUsage();try{return fn(...callArgs);}finally{const used=process.cpuUsage(cpu);profile.native_calls.push({phase,name,method,wall_ms:performance.now()-start,cpu_ms:(used.user+used.system)/1000});}};
  };return mod;
 };
 phase='kernel';kernel=await timed('kernel_total',()=>createKernel(measuredTome,{wasmBinary:wasm,getPreloadedPackage:()=>bytes.buffer.slice(bytes.byteOffset,bytes.byteOffset+bytes.byteLength)},{prepare:encounter?mod=>timed('encounter_prepare',()=>installEncounter(mod,encounter)):undefined}));
 const originalRpc=kernel.rpc;kernel.rpc=async(...args)=>{const start=performance.now();try{return await originalRpc(...args);}finally{profile.rpc.push({phase,method:args[0],wall_ms:performance.now()-start});}};
 const init=BattleSession.prototype.init,execute=BattleSession.prototype.execute;
 BattleSession.prototype.init=async function(...args){const before=phase;phase='restore/init';try{return await timed('restore_init',()=>init.apply(this,args));}finally{phase=before;}};
 BattleSession.prototype.execute=async function(kind,...args){const before=phase;phase=before==='restore'?'restore/event:'+kind:before;const start=performance.now();try{return await execute.call(this,kind,...args);}finally{profile.executions.push({phase,kind,wall_ms:performance.now()-start});phase=before;}};
 phase='restore';const session=await timed('restore_total',()=>BattleSession.restore(kernel.rpc,identity.build_id,request.archive));
 const results=[];
 for(const operation of request.operations){
  if(!['campaign_items','campaign_reconcile'].includes(operation.operation))throw Error('diagnostic operation not supported');
  phase='new/'+operation.operation;
  const body=operation.operation==='campaign_items'?{world_id:operation.world_id,request:operation.request}:{world_id:operation.world_id,world_location:operation.world_location,observation_id:operation.observation_id};
  const result=await timed('operation_'+operation.operation,()=>session.execute(operation.operation,body));if(result.status!==200)throw Error('native transition failed');results.push(result.transition);
 }
 phase='suspend';const archive=await timed('suspend_total',()=>session.suspend());
 phase='inspect';const native=await timed('native_inspect',()=>kernel.rpc('dm_inspect',{},session.bridge.generation));
 const value={ok:true,archive,view:session.bridge.state(),native,results};
 const serialized=await timed('result_serialize',()=>JSON.stringify(value));
 await timed('result_file_write',()=>writeFile(output,serialized));
 phase='dispose';await timed('dispose',()=>kernel.dispose());kernel=null;
 profile.inner_wall_ms=performance.now()-began;const used=process.cpuUsage(cpuBegan);profile.inner_cpu_ms=(used.user+used.system)/1000;
 await writeFile(output+'.profile.json',JSON.stringify(profile,null,2));
 console.log(JSON.stringify({ok:true,inner_wall_ms:profile.inner_wall_ms,events:profile.events}));
}catch(error){await writeFile(output+'.error.txt',String(error.stack||error));process.exitCode=1;}
finally{kernel?.dispose();}
