import test from 'node:test';
import assert from 'node:assert/strict';
import {BattleSession} from '../tome_mvp/wasm/battle_session.mjs';

function runtime(){
 let turn=0;const calls=[];
 const rpc=async(method,p={})=>{
  calls.push(method);
  if(method==='capabilities')return {protocol:'tome-headless-v1',methods:{observe:true},web_commands:{}};
  if(method==='create')return {accepted:true,generation:1,boundary:'decision'};
  if(method==='observe')return {generation:1,map:['.'],party:[{id:1}],enemies:[],events:[],status:'active',turn,capabilities:{}};
  if(method==='snapshot_export')return {format:'tome-native-save-v1',blob:JSON.stringify({turn}),generation:1,boundary:'decision'};
  if(method==='snapshot_import'){turn=JSON.parse(p.blob).turn;return {generation:1,boundary:'decision'};}
  throw Error('unexpected RPC '+method);
 };
 return {rpc,calls};
}
test('native session restores directly without create or historical replay',async()=>{
 const a=runtime(),s=new BattleSession(a.rpc,'build',7);await s.init();s.suspended=true;
 const archive=await s.checkpoint();assert.equal(archive.events.length,0);
 const b=runtime(),loaded=await BattleSession.restore(b.rpc,'build',archive);
 assert.equal(loaded.bridge.state().turn,0);assert.deepEqual(b.calls,['capabilities','snapshot_import','observe']);
});
test('native session rejects incompatible state and unstable checkpoint',async()=>{
 const a=runtime(),s=new BattleSession(a.rpc,'build',7);await s.init();s.suspended=true;
 s.bridge.pending=true;await assert.rejects(s.checkpoint(),/boundary/);s.bridge.pending=false;
 const archive=await s.checkpoint();archive.base.final='forged';
 await assert.rejects(BattleSession.restore(runtime().rpc,'build',archive),/state mismatch/);
 await assert.rejects(BattleSession.restore(runtime().rpc,'other',archive),/incompatible/);
});
test('partition browser archive contains only committed base and incremental events',async()=>{
 const r=runtime(),s=new BattleSession(r.rpc,'build',7);await s.init();s.suspended=true;s.partitionOnly=true;
 await assert.rejects(s.archive(),/authoritative host/);
 s.partitionBase={version:2,manifest_sha256:'trusted'};s.audit=[];const a=await s.archive();
 assert.equal(a.format,'tome-partition-session-v1');assert.deepEqual(a.events,[]);assert.equal(a.base.version,2);assert.equal('blobs' in a,false);
});
