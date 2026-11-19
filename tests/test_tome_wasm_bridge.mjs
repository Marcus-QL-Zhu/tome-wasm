import {test} from 'node:test';
import assert from 'node:assert/strict';
import {EngineBridge} from '../tome_mvp/wasm/engine_bridge.mjs';
function fake() {
 let gen=1, ai='stopped', calls=[], boundary='decision', events=[];
 const capabilities=Object.fromEntries(['move','wait','pause','new_game','ai_start','ai_step','confirm_down','rescue_step','navigate_start','navigate_step'].map(k=>[k,true]));
 const rpc=async(method,p={},g)=>{calls.push([method,p,g]); if(method==='capabilities') return {protocol:'tome-headless-v1',ai_provider:'player_aioo_custom',web_commands:capabilities,methods:{observe:true,ai_stop:true,advance:true}};
 if(method==='create') return {accepted:true,generation:gen,boundary};
 if(method==='reset') return {accepted:true,generation:++gen,boundary:'decision'};
 if(method==='observe') return {generation:gen,fixture:'formal',map:['@'],party:[{id:1}],enemies:[],events:[],turn:0,status:boundary==='terminal'?'defeat':'active',capabilities,ai_status:ai,ai_epoch:7,down_events:events};
 if(method==='act') {if(p.type==='ai_start') ai='running'; if(p.type==='ai_stop') {ai='stopped';return {accepted:true,generation:gen,boundary:'decision',ai_epoch:7};}return {accepted:true,generation:gen,boundary,ai_epoch:7};}
 if(method==='advance') {boundary='decision';return {accepted:true,generation:gen,boundary};}
 };
 return {rpc,calls,setBoundary:x=>boundary=x,setEvents:x=>events=x};
}
test('state is cached; action observes once; stale requests do not act',async()=>{let f=fake(), b=new EngineBridge(f.rpc);await b.init();let n=f.calls.length; b.state();b.state();assert.equal(f.calls.length,n);let r=await b.command({type:'move',dx:1,dy:0,revision:0});assert.equal(r.status,200);assert.equal(f.calls.slice(n).filter(x=>x[0]==='observe').length,1);n=f.calls.length;assert.equal((await b.command({type:'wait',revision:0})).status,409);assert.equal(f.calls.length,n);});
test('budget consumes one step and explicitly stops; old epoch rejected',async()=>{let f=fake(),b=new EngineBridge(f.rpc);await b.init();let start=await b.command({type:'ai_start',budget:1,revision:0});assert.equal(start.body.ai_remaining,1);let epoch=start.body.control_epoch;let r=await b.command({type:'ai_step',revision:1,control_epoch:epoch});assert.equal(r.body.ai_control_reason,'budget_exhausted');assert.equal(r.body.ai_status,'stopped');assert.equal((await b.command({type:'ai_step',revision:2,control_epoch:epoch})).status,409);assert.ok(f.calls.some(x=>x[1].type==='native_ai'));});
test('reset changes generation and rejects old down event',async()=>{let f=fake(),b=new EngineBridge(f.rpc);await b.init();let r=await b.command({type:'new_game',seed:12,revision:0});assert.equal(r.body.generation,2);r=await b.command({type:'confirm_down',event_id:1,generation:1,revision:1});assert.equal(r.status,400);});
test('unknown native outcome permanently locks state and commands',async()=>{let f=fake(), b=new EngineBridge(async (...args)=>{if(args[0]==='act') throw Error('unknown'); return f.rpc(...args)});await b.init();assert.equal((await b.command({type:'wait',revision:0})).status,500);assert.equal(b.state().online,false);assert.equal((await b.command({type:'new_game',revision:1})).status,500);});
test('pending drain is bounded and unsupported save cannot call native',async()=>{let f=fake(), b=new EngineBridge(f.rpc);await b.init();f.setBoundary('pending');let r=await b.command({type:'wait',revision:0});assert.equal(r.body.advance_status,'decision');let n=f.calls.length;assert.equal((await b.command({type:'save',revision:1})).status,403);assert.equal(f.calls.length,n);});

function pendingFake(endBoundary='decision') {
 const f=fake(); let remaining=3, active=false, ended=false;
 const rpc=async(method,p,g)=>{
   if(method==='act' && p.type==='native_ai') {active=true; await f.rpc(method,p,g); return {accepted:true,generation:1,boundary:'pending',ai_epoch:7};}
   if(method==='advance' && active) {f.calls.push([method,p,g]); if(remaining-->0) return {accepted:true,generation:1,boundary:'pending',ai_epoch:7}; ended=true; if(endBoundary==='input') f.setEvents([{event_id:1,actor_id:1}]); return {accepted:true,generation:1,boundary:endBoundary,ai_epoch:7,input_request:endBoundary==='input'?{kind:'down'}:undefined};}
   return f.rpc(method,p,g);
 };
 return {...f,rpc,isEnded:()=>ended};
}
test('exhausted budget preserves pending then stops at decision',async()=>{
 let f=pendingFake(),b=new EngineBridge(f.rpc);await b.init();let a=await b.command({type:'ai_start',budget:1,revision:0});
 let r=await b.command({type:'ai_step',revision:1,control_epoch:a.body.control_epoch});assert.equal(r.status,200);assert.equal(r.body.advance_status,'pending');assert.equal(r.body.ai_remaining,0);assert.equal(r.body.ai_control_reason,'budget_exhausted');assert.equal(f.calls.filter(x=>x[0]==='advance').length,3);
 r=await b.command({type:'continue_pending',revision:2});assert.equal(r.status,200);assert.equal(r.body.advance_status,'decision');assert.equal(r.body.ai_status,'stopped');assert.equal(f.calls.filter(x=>x[1].type==='ai_stop' && x[1].reason==='budget').length,1);
});
test('pending budget reaching down input preserves explicit confirmation',async()=>{
 let f=pendingFake('input'),b=new EngineBridge(f.rpc);await b.init();let a=await b.command({type:'ai_start',budget:1,revision:0});await b.command({type:'ai_step',revision:1,control_epoch:a.body.control_epoch});let r=await b.command({type:'continue_pending',revision:2});
 assert.equal(r.status,200);assert.equal(r.body.advance_status,'input');assert.equal(r.body.down_events.length,1);assert.equal(r.body.ai_remaining,0);assert.equal(r.body.capabilities.ai_start,false);assert.equal(f.calls.filter(x=>x[1].type==='ai_stop' && x[1].reason==='budget').length,0);
});
test('pending exhausted budget rejects old AI epoch without another native action',async()=>{
 let f=pendingFake(),b=new EngineBridge(f.rpc);await b.init();let a=await b.command({type:'ai_start',budget:1,revision:0});let epoch=a.body.control_epoch;await b.command({type:'ai_step',revision:1,control_epoch:epoch});let n=f.calls.length;
 let r=await b.command({type:'ai_step',revision:2,control_epoch:epoch});assert.equal(r.status,409);assert.equal(f.calls.length,n);assert.equal(f.calls.filter(x=>x[1].type==='native_ai').length,1);
});
test('pause during budget pending revokes authorization without advancing',async()=>{
 let f=pendingFake(),b=new EngineBridge(f.rpc);await b.init();let a=await b.command({type:'ai_start',budget:1,revision:0});let epoch=a.body.control_epoch;await b.command({type:'ai_step',revision:1,control_epoch:epoch});let n=f.calls.length;
 let r=await b.command({type:'pause',revision:0});assert.equal(r.status,200);assert.equal(r.body.advance_status,'pending');assert.equal(r.body.ai_remaining,0);assert.equal(f.calls.length,n);assert.equal((await b.command({type:'ai_step',revision:3,control_epoch:epoch})).status,409);
 r=await b.command({type:'continue_pending',revision:3});assert.equal(r.status,200);assert.equal(r.body.ai_status,'stopped');
});
test('AI can explicitly restart after budget stop, including deferred pending stop',async()=>{
 for(const make of [fake,pendingFake]) {
  const f=make(),b=new EngineBridge(f.rpc);await b.init();let start=await b.command({type:'ai_start',budget:1,revision:0});let r=await b.command({type:'ai_step',revision:1,control_epoch:start.body.control_epoch});
  if(r.body.advance_status==='pending') r=await b.command({type:'continue_pending',revision:r.body.revision});
  assert.equal(r.body.capabilities.ai_start,true);let again=await b.command({type:'ai_start',budget:1,revision:r.body.revision});assert.equal(again.status,200);assert.equal(again.body.ai_status,'running');
 }
});

test('continuous budget renews only at boundary without restarting native AI',async()=>{
 const f=fake(), rpc=async(...a)=>{const r=await f.rpc(...a);if(a[0]==='capabilities') r.ai_modes=['sweep','explore','rest'];return r;}, b=new EngineBridge(rpc);await b.init();
 let r=await b.command({type:'ai_start',mode:'explore',continuous:true,budget:1,revision:0});const epoch=r.body.control_epoch;
 assert.equal(f.calls.find(x=>x[1].type==='ai_start')[1].mode,'explore');
 r=await b.command({type:'ai_step',revision:r.body.revision,control_epoch:epoch});assert.equal(r.body.capabilities.ai_renew,true);assert.equal(r.body.ai_status,'running');
 let n=f.calls.length;assert.equal((await b.command({type:'ai_renew',budget:1,revision:r.body.revision,control_epoch:epoch+1})).status,409);assert.equal(f.calls.length,n);
 r=await b.command({type:'ai_renew',budget:1,revision:r.body.revision,control_epoch:epoch});assert.equal(r.body.ai_remaining,1);assert.equal(f.calls.filter(x=>x[1].type==='ai_start').length,1);
 assert.equal((await b.command({type:'ai_renew',budget:1,revision:r.body.revision,control_epoch:epoch})).status,403);
 r=await b.command({type:'pause',revision:r.body.revision});assert.equal((await b.command({type:'ai_renew',budget:1,revision:r.body.revision,control_epoch:epoch})).status,409);
});
test('continuous pending down event cannot renew or confirm automatically',async()=>{
 const f=pendingFake('input'),b=new EngineBridge(f.rpc);await b.init();let r=await b.command({type:'ai_start',continuous:true,budget:1,revision:0});const epoch=r.body.control_epoch;
 r=await b.command({type:'ai_step',revision:r.body.revision,control_epoch:epoch});assert.equal(r.body.advance_status,'pending');assert.equal(r.body.capabilities.ai_renew,false);
 r=await b.command({type:'continue_pending',revision:r.body.revision});assert.equal(r.body.advance_status,'input');assert.equal(r.body.down_events.length,1);assert.equal(r.body.capabilities.ai_renew,false);
 assert.equal((await b.command({type:'ai_renew',revision:r.body.revision,control_epoch:epoch,budget:1})).status,409);assert.equal(f.calls.filter(x=>x[1].type==='confirm_down').length,0);
});
test('undeclared native modes are rejected without an action',async()=>{
 const f=fake(),b=new EngineBridge(f.rpc);await b.init();let n=f.calls.length;let r=await b.command({type:'ai_start',mode:'rest',budget:1,revision:0});assert.equal(r.status,400);assert.equal(f.calls.length,n);
});
