import {test} from 'node:test';
import assert from 'node:assert/strict';
import {BattleSession} from '../tome_mvp/wasm/battle_session.mjs';
function nativeStub(boundary){
 const calls=[];const rpc=async(method,p)=>{
  calls.push([method,p]);
  if(method==='capabilities')return {protocol:'tome-headless-v1',methods:{observe:true,ai_stop:true},web_commands:{wait:true}};
  if(method==='create')return {accepted:true,generation:1,boundary};
  if(method==='observe')return {generation:1,map:['@'],party:[{id:1}],enemies:[],events:[],turn:1,status:boundary==='terminal'?'defeat':'active',capabilities:{wait:true},ai_status:'stopped',input_request:boundary==='await_input'?{id:1,kind:'target',prompt:'second target'}:null};
  throw Error('unexpected native action '+method);
 };return {rpc,calls};
}
test('saving an unfinished native choice never answers or cancels it',async()=>{
 const first=nativeStub('await_input'),s=new BattleSession(first.rpc,'test-build',23);await s.init();const doc=await s.suspend();assert.equal(doc.events.length,0);assert.equal(first.calls.filter(x=>x[0]==='respond_input').length,0);
 const second=nativeStub('await_input'),r=await BattleSession.restore(second.rpc,'test-build',doc);assert.equal(r.bridge.state().input_request.prompt,'second target');assert.equal(second.calls.filter(x=>x[0]==='respond_input').length,0);
});
test('terminal saves do not ask the native engine to resume or stop an ended game',async()=>{
 const first=nativeStub('terminal'),s=new BattleSession(first.rpc,'test-build',23);await s.init();const doc=await s.suspend();assert.equal(doc.events.length,1);assert.equal(first.calls.filter(x=>x[0]==='act').length,0);
 const second=nativeStub('terminal'),r=await BattleSession.restore(second.rpc,'test-build',doc);assert.equal(r.bridge.state().status,'defeat');assert.equal(r.bridge.locked,false);
});
test('unknown native results cannot become valid archives',async()=>{
 const f=nativeStub('decision'),s=new BattleSession(f.rpc,'test-build',23);await s.init();const bad=await s.execute('command',{type:'wait',revision:0});assert.equal(bad.status,500);await assert.rejects(s.suspend());
});

test('saving a pending action never advances its unfinished rule callbacks',async()=>{
 const f=nativeStub('pending'),s=new BattleSession(f.rpc,'test-build',23);await s.init();
 const before=f.calls.length;await assert.rejects(s.suspend(),/still settling/);
 assert.equal(f.calls.length,before);assert.equal(s.events.length,0);assert.equal(s.suspended,false);
});
