import test from 'node:test';
import assert from 'node:assert/strict';
import {createKernel} from '../tome_mvp/wasm/kernel_runtime.mjs';
function fake(heap){
 let reply='{}',freed=false,mode;const mod={};
 if(heap){mod.HEAPU8=new Uint8Array(7*1024*1024);mod._malloc=()=>16;mod._free=()=>{freed=true;};}
 if(!heap)Object.defineProperty(mod,'HEAPU8',{get(){throw Error('unexported getter must not run');}});
 mod.cwrap=(name,_r,args)=>{
  if(name==='tome_init')return ()=>0;
  if(name==='tome_free')return ()=>{};
  if(name==='tome_result')return ()=>reply;
  if(name==='tome_request'){mode=args[0];return arg=>{let raw=arg;if(mode==='number'){const end=mod.HEAPU8.indexOf(0,arg);raw=new TextDecoder().decode(mod.HEAPU8.subarray(arg,end));}const q=JSON.parse(raw);reply=JSON.stringify({id:q.id,ok:true,result:{received:q.params.blob.length}});return 0;};}
 };
 return {create:async()=>mod,freed:()=>freed,mode:()=>mode};
}
test('large native request uses heap and releases allocation',async()=>{
 const f=fake(true),k=await createKernel(f.create);const result=await k.rpc('snapshot_import',{blob:'x'.repeat(5*1024*1024)});
 assert.equal(result.received,5*1024*1024);assert.equal(f.mode(),'number');assert.equal(f.freed(),true);
});
test('old runtime refuses large requests without stack allocation',async()=>{
 const f=fake(false),k=await createKernel(f.create);
 await assert.rejects(k.rpc('snapshot_import',{blob:'x'.repeat(300*1024)}),/heap transport unavailable/);assert.equal(f.mode(),'string');
});
