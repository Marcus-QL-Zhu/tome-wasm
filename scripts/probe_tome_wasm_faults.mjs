// Controlled native failures, defeat and rescue against real Wasm.
import {readFile,writeFile,mkdir} from 'node:fs/promises';
import {resolve} from 'node:path';
import {pathToFileURL} from 'node:url';
import assert from 'node:assert/strict';
const root=resolve(process.argv[2]),out=resolve(process.argv[3]);
const {default:createTome}=await import(pathToFileURL(resolve(root,'tome.js')));
const {EngineBridge}=await import(pathToFileURL(resolve(root,'engine_bridge.mjs')));
const bytes=await readFile(resolve(root,'tome.data')),reports=[];
for(const mode of ['unknown','defeat','rescue']){
 const logs=[];const mod=await createTome({wasmBinary:await readFile(resolve(root,'tome.wasm')),getPreloadedPackage:()=>bytes.buffer.slice(bytes.byteOffset,bytes.byteOffset+bytes.byteLength),print:(...p)=>logs.push(p.join(' ')),printErr:(...p)=>logs.push(p.join(' '))});
 const path='/bundle/headless/worker.lua',original=mod.FS.readFile(path,{encoding:'utf8'});
 const hook=`
local test_create=scenario.create
scenario={create=function(...)
 local s=test_create(...);local wait=s.player.waitTurn
 s.player.waitTurn=function(self,...)
  self.waitTurn=wait
  ${mode==='unknown'?"error('test_injected_native_failure')":`local result=wait(self,...)
  ${mode==='defeat'?"for _,a in ipairs(s.allies) do a:takeHit(1000000,s.enemy) end":"s.allies[2]:takeHit(1000000,s.enemy)"}
  return result`}
 end
 return s
end}
`;
 mod.FS.writeFile(path,original.replace("local scenario = require 'scene'","local scenario = require 'scene'\n"+hook));
 const init=mod.cwrap('tome_init','number',[]),send=mod.cwrap('tome_request','number',['string']),result=mod.cwrap('tome_result','string',[]);assert.equal(init(),0);
 let seq=0,calls=0;const rpc=async(method,params={},generation)=>{calls++;const q={protocol:'tome-headless-v1',id:++seq,method,params};if(generation!=null)q.expected_generation=generation;const rc=send(JSON.stringify(q));const reply=JSON.parse(result());if(reply.ok)return reply.result;const e=Error(reply.error?.code);e.outcome=reply.error?.outcome;throw e;};
 const b=new EngineBridge(rpc);let s=await b.init(12);const initial=structuredClone(s),states=[];
 async function command(p){const r=await b.command({...p,revision:s.revision});states.push({p,status:r.status,turn:r.body.turn,state:r.body.status,stale:r.body.stale});s=r.body;return r;}
 let r=await command({type:'wait'});
 if(mode==='unknown'){
  assert.equal(r.status,500);s=b.state();assert.equal(s.stale,true);assert.deepEqual(s.map,initial.map);assert.deepEqual(s.party,initial.party);const count=calls;assert.equal((await b.command({type:'wait',revision:s.revision})).status,500);assert.equal(calls,count);
 }else if(mode==='defeat'){
  assert.equal(s.status,'defeat');assert.equal(s.advance_status,'terminal');assert.equal(s.party.filter(p=>p.down).length,3);assert.equal(s.map.length,20);assert.equal(b.locked,false);
 }else{
  assert.equal(s.down_events.length,1);assert.equal(s.advance_status,'input');assert.equal(s.capabilities.ai_start,false);
  await command({type:'confirm_down',event_id:s.down_events[0].id,generation:s.generation});
  while(s.advance_status==='pending')assert.equal((await command({type:'continue_pending'})).status,200);
  const target=s.party.find(p=>p.down);assert.ok(target);assert.equal((await command({type:'rescue_start',target:target.id})).status,200);
  for(let i=0;i<25 && s.rescue_progress;i++)assert.equal((await command({type:'rescue_step',control_epoch:s.control_epoch})).status,200);
  assert.equal(s.rescue_progress,null);assert.equal(s.party.find(p=>p.id===target.id).down,false);assert.equal(b.locked,false);
 }
 reports.push({mode,passed:true,final:{status:s.status,stale:s.stale,turn:s.turn,map_rows:s.map.length,party:s.party.map(p=>({name:p.name,hp:p.hp,down:p.down}))},states,logs:logs.slice(-8)});mod.cwrap('tome_free',null,[])();
}
await mkdir(resolve(out,'..'),{recursive:true});await writeFile(out,JSON.stringify(reports,null,2));console.log('real Wasm unknown, defeat and rescue passed');
