import {test} from 'node:test';
import assert from 'node:assert/strict';
import {EngineBridge,validateObservation} from '../tome_mvp/wasm/engine_bridge.mjs';
function fixture(){
 let actor=1,ai='stopped',boundary='decision',serial=0;const calls=[];
 const capabilities={native_control:true,ai_start:true,ai_step:true};
 const rpc=async(method,p={})=>{calls.push([method,p]);
  if(method==='capabilities')return {protocol:'tome-headless-v1',ai_provider:'player_aioo_custom',web_commands:capabilities,methods:{observe:true,ai_stop:true}};
  if(method==='create')return {accepted:true,generation:1,boundary};
  if(method==='observe')return {generation:1,fixture:'formal',map:['@f'],party:[{id:1}],enemies:[],events:[],turn:0,status:'active',control_actor_id:actor,controlled_actor:{id:actor},control_change:serial?{serial,current:actor}:null,control_targets:[{id:actor===1?9:1,name:'owned body'}],ai_status:ai,ai_epoch:4,capabilities};
  if(method==='act'){
   if(p.type==='ai_start')ai='running';
   if(p.type==='ai_stop')ai='stopped';
   if(p.type==='native_control'){actor=Number(p.target);ai='stopped';serial++;}
   return {accepted:true,generation:1,boundary,ai_epoch:4};
  }
 };
 return {rpc,calls,change:()=>{actor=9;ai='stopped';serial++;},roundtrip:()=>{serial+=2;},pending:()=>boundary='await_input'};
}
test('explicit body switch revokes old AI authorization',async()=>{
 const f=fixture(),b=new EngineBridge(f.rpc);await b.init();
 const start=await b.command({type:'ai_start',budget:5,revision:b.revision}),old=start.body.control_epoch;
 const r=await b.command({type:'native_control',target:'9',revision:b.revision});assert.equal(r.status,200);assert.equal(r.body.control_actor_id,9);assert.equal(b.authorized,false);
 const n=f.calls.length;assert.equal((await b.command({type:'ai_step',control_epoch:old,revision:b.revision})).status,409);assert.equal(f.calls.length,n);
});
test('native automatic return also revokes authorization on observation',async()=>{
 const f=fixture(),b=new EngineBridge(f.rpc);await b.init();await b.command({type:'ai_start',budget:5,revision:b.revision});f.change();await b.observe();assert.equal(b.authorized,false);assert.equal(b.state().ai_control_reason,'control_changed');
});
test('body switching rejects malformed input before native execution',async()=>{
 const f=fixture(),b=new EngineBridge(f.rpc);await b.init();const n=f.calls.length;
 assert.equal((await b.command({type:'native_control',target:'9',bypass:true,revision:b.revision})).status,400);assert.equal(f.calls.length,n);
 assert.equal((await b.command({type:'native_control',target:'enemy',revision:b.revision})).status,400);
});
test('controlled projection cannot identify a different body',()=>{
 const s={generation:1,map:['@'],party:[{id:1}],enemies:[],events:[],turn:0,status:'active',control_actor_id:9,controlled_actor:{id:1}};
 assert.throws(()=>validateObservation(s,1,'decision'),/invalid observation/);
});
test('pending native choice blocks body switching without another RPC',async()=>{
 const f=fixture(),b=new EngineBridge(f.rpc);await b.init();
 f.pending();b.receipt({accepted:true,generation:1,boundary:'await_input'});await b.observe();
 const n=f.calls.length;assert.equal((await b.command({type:'native_control',target:'9',revision:b.revision})).status,403);assert.equal(f.calls.length,n);
});
test('same-body return serial still revokes the old AI epoch',async()=>{
 const f=fixture(),b=new EngineBridge(f.rpc);await b.init();const r=await b.command({type:'ai_start',budget:5,continuous:true,revision:b.revision});
 f.roundtrip();await b.observe();assert.equal(b.state().control_actor_id,1);assert.equal(b.authorized,false);assert.equal(b.state().ai_remaining,0);assert.equal(b.state().ai_control_reason,'control_changed');assert.equal(b.state().capabilities.ai_renew,false);
 assert.equal((await b.command({type:'ai_step',revision:b.revision,control_epoch:r.body.control_epoch})).status,409);
});
