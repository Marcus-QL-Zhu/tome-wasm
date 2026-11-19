import {validateObservation} from './engine_bridge.mjs';
export async function createKernel(createTome,options={},hooks={}){
 let seq=0,boundary,scriptError=null;
 const log=(...parts)=>{
  const line=parts.map(String).join(' ');
  if(line.startsWith('HEADLESS_TALENT_ERROR_STACK_JSON') || line.includes('##Use Talent Lua Error##'))scriptError=scriptError || line;
  hooks.log?.(...parts);
 };
 const mod=await createTome({...options,print:log,printErr:log});
 if(hooks.prepare)await hooks.prepare(mod);
 const init=mod.cwrap('tome_init','number',[]),result=mod.cwrap('tome_result','string',[]);
 const mallocProp=Object.getOwnPropertyDescriptor(mod,'_malloc'),freeProp=Object.getOwnPropertyDescriptor(mod,'_free'),heapProp=Object.getOwnPropertyDescriptor(mod,'HEAPU8');
 // Emscripten installs throwing getters for unexported names. Never invoke
 // those getters while detecting compatibility with an older frozen build.
 const heapSend=typeof mallocProp?.value==='function' && typeof freeProp?.value==='function' && heapProp?.value instanceof Uint8Array;
 const send=mod.cwrap('tome_request','number',[heapSend?'number':'string']);
 function sendRequest(value){
  const bytes=new TextEncoder().encode(value);
  if(bytes.byteLength>80*1024*1024)throw Error('native request capacity exceeded');
  // Older frozen packages may lack exported allocators. Never put a large
  // request on their fixed Wasm stack.
  if(!heapSend){if(bytes.byteLength>256*1024)throw Error('native heap transport unavailable');return send(value);}
  const ptr=mod._malloc(bytes.byteLength+1);if(!ptr)throw Error('native request allocation failed');
  try{mod.HEAPU8.set(bytes,ptr);mod.HEAPU8[ptr+bytes.byteLength]=0;return send(ptr);}
  finally{mod._free(ptr);}
 }

 if(init()!==0){const detail=String(result() || '').slice(0,1000);throw Error('Wasm initialization failed'+(detail?': '+detail:''));}
 return {mod,dispose:()=>mod.cwrap('tome_free',null,[])(),rpc:async(method,params={},generation)=>{
  hooks.request?.(method,params,generation);scriptError=null;
  const req={protocol:'tome-headless-v1',id:++seq,method,params};if(generation!=null)req.expected_generation=generation;
  let rc;
  try{rc=sendRequest(JSON.stringify(req));}catch(e){hooks.fail?.('wasm_trap',String(e.stack || e));throw e;}
  if(scriptError){hooks.fail?.('native_script_error',scriptError);throw Error('native script outcome unknown');}
  let reply;try{reply=JSON.parse(result());}catch(e){hooks.fail?.('invalid_native_json',result());throw Error('invalid native response: '+result().slice(0,1000));}
  if(reply.id!==seq || typeof reply.ok!=='boolean')throw Error('invalid native envelope');
  if(rc===0 && reply.ok===true && 'result' in reply && !('error' in reply)){
   if(['create','reset','act','advance','dm_transition','campaign_next','campaign_items','campaign_adopt','campaign_reconcile','campaign_settle','campaign_wipeout','respond_input'].includes(method) && reply.result.accepted===true)boundary=reply.result.boundary;
   if(method==='observe'){validateObservation(reply.result,generation,boundary);hooks.observe?.(reply.result);}
   return reply.result;
  }
  if(reply.ok===false && reply.error?.outcome==='rejected' && !('result' in reply)){const e=Error(reply.error.code);e.outcome='rejected';throw e;}
  hooks.fail?.(reply.error?.code || 'native_failure',result());throw Error('native outcome unknown');
 }};
}
