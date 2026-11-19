import {test} from 'node:test';
import assert from 'node:assert/strict';
import {BattleSession} from '../tome_mvp/wasm/battle_session.mjs';
import {validateObservation} from '../tome_mvp/wasm/engine_bridge.mjs';
function native(){
 let step=0;
 return async(method,p)=>{
  if(method==='capabilities')return {protocol:'tome-headless-v1',methods:{observe:true,ai_stop:true},web_commands:{wait:true}};
  if(method==='create')return {accepted:true,generation:1,boundary:'decision'};
  if(method==='act'){if(p.type==='wait')step++;return {accepted:true,generation:1,boundary:'decision'};}
  if(method==='observe')return {generation:1,map:['@'],party:[{id:1}],enemies:[],events:[],turn:step,status:'active',capabilities:{wait:true},ai_status:'stopped',rule_events:[{id:1,kind:'particle_remove:meteor',phase:step?'done':'pending',turn:1,x:0,y:0}]};
  throw Error('unexpected method');
 };
}
test('rule receipts enter the full log once per transition and survive replay',async()=>{
 const s=new BattleSession(native(),'test',23);await s.init();
 await s.execute('command',{type:'wait',revision:0});await s.execute('command',{type:'wait',revision:1});
 assert.equal(s.events[0].rule_events[0].phase,'done');assert.equal(s.events[1].rule_events,undefined);
 const archive=await s.suspend(),copy=await BattleSession.restore(native(),'test',archive);assert.deepEqual(copy.bridge.state(),s.bridge.state());
 const forged=structuredClone(archive);forged.events[0].rule_events[0].kind='forged';await assert.rejects(BattleSession.restore(native(),'test',forged),/replay diverged/);
});
test('invalid rule-event envelopes cannot replace a known battlefield',()=>{
 const base={generation:1,map:['@'],party:[{id:1}],enemies:[],events:[],turn:1,status:'active'};
 for(const rule_events of [{},[{id:1,kind:'meteor',phase:'done',turn:1,x:NaN,y:0}],[{id:1,kind:'meteor',phase:'running',turn:1,x:0,y:0}]])assert.throws(()=>validateObservation({...base,rule_events},1,'decision'),/invalid observation/);
});
