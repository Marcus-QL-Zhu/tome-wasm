// Load a real compiled kernel. The natural case follows the user's seed and UI intent.
import {readFile,writeFile,mkdir} from 'node:fs/promises';
import {resolve,dirname} from 'node:path';
import {pathToFileURL} from 'node:url';
import assert from 'node:assert/strict';
import {EngineBridge} from '../tome_mvp/wasm/engine_bridge.mjs';
const root=resolve(process.argv[2]),output=resolve(process.argv[3]),mode=process.argv[4] || 'natural',old=process.argv.includes('--expect-old-lock');
const lines=[],report={runtime:'real Wasm',mode,old_expected:old,steps:0};let m;
try{
 const {default:createTome}=await import(pathToFileURL(resolve(root,'tome.js')));const bytes=await readFile(resolve(root,'tome.data'));
 m=await createTome({wasmBinary:await readFile(resolve(root,'tome.wasm')),getPreloadedPackage:()=>bytes.buffer.slice(bytes.byteOffset,bytes.byteOffset+bytes.byteLength),print:(...s)=>{lines.push(s.join(' '));if(lines.length>70)lines.shift();},printErr:(...s)=>{lines.push(s.join(' '));if(lines.length>70)lines.shift();}});
 if(mode!=='natural'){
  assert.ok(['blocked','success','cancelled','fault','reported_error','pending_input'].includes(mode));
  const fixture=String.raw`
local base_create=scenario.create
scenario.create=function(...)
 local s=base_create(...)
 local floor=s.map(s.player.x,s.player.y,s.Map.TERRAIN)
 for x=1,18 do for y=1,18 do s.map(x,y,s.Map.TERRAIN,floor:clone());s.map.lites(x,y,true) end end
 local actors={};for _,a in ipairs(s.allies) do actors[#actors+1]=a end;for _,a in ipairs(s.enemies) do actors[#actors+1]=a end
 for _,a in ipairs(actors) do s.map:remove(a.x,a.y,s.Map.ACTOR);a.x=nil;a.y=nil end
 local positions={{5,10},{MODE=='blocked' and 6 or 4,10},{4,11},{9,10},{16,16}}
 for i,a in ipairs(actors) do local pos=positions[i] or {16,i-1};a:move(pos[1],pos[2],true) end
 if MODE=='fault' then s.player:getTalentFromId('T_RUSH').action=function()error('RUSH_OUTCOME_REAL_SCRIPT_FAULT')end end
 if MODE=='reported_error' then s.player:getTalentFromId('T_RUSH').action=function(self,t)self:onTalentLuaError(t,'RUSH_OUTCOME_REPORTED_FAULT');return nil end end
 if MODE=='cancelled' then s.player:getTalentFromId('T_RUSH').action=function()return nil end end
 if MODE=='pending_input' then s.player:getTalentFromId('T_RUSH').action=function()game.__coroutines.rush_probe=true;return nil end end
 s.map.clean_fov=true;s.player:doFOV()
 return s
end
`.replaceAll('MODE',JSON.stringify(mode));
  const path='/bundle/headless/worker.lua',source=m.FS.readFile(path,{encoding:'utf8'});m.FS.writeFile(path,source.replace("local scenario = require 'scene'","local scenario = require 'scene'\n"+fixture));
 }
 assert.equal(m.cwrap('tome_init','number',[])(),0);
 const send=m.cwrap('tome_request','number',['string']),result=m.cwrap('tome_result','string',[]);let seq=0;
 const rpc=async(method,params={},generation)=>{const req={protocol:'tome-headless-v1',id:++seq,method,params};if(generation!=null)req.expected_generation=generation;send(JSON.stringify(req));const r=JSON.parse(result());assert.equal(r.id,seq);if(!r.ok){const e=Error(r.error.code);e.outcome=r.error.outcome;throw e;}return r.result;};
 const b=new EngineBridge(rpc);let s=await b.init(23);
 async function command(p){const r=await b.command({...p,revision:s.revision});if(r.status===200)s=r.body;return r;}
 if(mode==='natural'){
  assert.equal((await command({type:'ai_start',mode:'explore',budget:500})).status,200);
  for(let i=0;i<250 && s.ai_status==='running';i++){
   const p=s.advance_status==='pending'?{type:'continue_pending'}:{type:'ai_step',control_epoch:s.control_epoch};const r=await command(p);assert.equal(r.status,200,JSON.stringify(r.body));report.steps++;
  }
  report.natural_stop={turn:s.turn,reason:s.ai_stop_reason,effects:s.party[0].effects};
  const diagnostic=JSON.parse(await readFile(resolve('artifacts/tome-rush-fix-20261112/user-diagnostics.json')));
  const expected=diagnostic.last_confirmed;
  const core=x=>({party:x.party.map(a=>({id:a.id,x:a.x,y:a.y,hp:a.hp,effects:a.effects})),enemies:x.enemies.map(a=>({id:a.id,x:a.x,y:a.y,hp:a.hp}))});
  report.matches_user_context=JSON.stringify(core(s))===JSON.stringify(core(expected));
  report.matches_user_prestate=report.matches_user_context && s.turn===expected.turn;
  report.user_turn=expected.turn;report.prior_history_truncated=true;
  assert.equal(report.matches_user_context,true,'natural run did not reproduce positions, health and effects');
 }
 const before=structuredClone(s),target=s.enemies.find(e=>e.id!==undefined);assert.ok(target,'no visible test target');
 report.before={turn:s.turn,actor:s.party[0],target};
 const r=await command({type:'talent',talent:'T_RUSH',target:String(target.id)});report.response_status=r.status;report.after=r.body;
 const shouldLock=old || mode==='fault' || mode==='reported_error' || mode==='pending_input';
 if(shouldLock){assert.equal(r.status,500);assert.equal(b.state().stale,true);report.lock_preserved=true;}
 else if(mode==='blocked'){
  assert.equal(r.status,400);assert.match(r.body.error,/blocked_target/);assert.equal(b.locked,false);s=b.state();assert.equal(s.turn,before.turn);
  assert.equal((await command({type:'wait'})).status,200);report.next_wait_accepted=true;
 }
 else {
  assert.equal(r.status,200,JSON.stringify(r.body));assert.equal(b.locked,false);
  if(mode==='natural'){assert.equal(s.last_action.outcome,'native_declined');assert.equal(s.last_action.energy_spent,true);assert.ok(s.turn>before.turn);assert.equal(s.talents.find(t=>t.id==='T_RUSH').cooldown,false);}
  if(mode==='cancelled'){assert.equal(s.last_action.outcome,'native_declined');assert.equal(s.last_action.energy_spent,false);assert.equal(s.turn,before.turn);assert.equal(s.party[0].x,before.party[0].x);}
  if(mode==='success'){assert.equal(s.last_action,null);assert.ok(s.talents.find(t=>t.id==='T_RUSH').cooldown>0);assert.ok(Math.max(Math.abs(s.party[0].x-target.x),Math.abs(s.party[0].y-target.y))<=1);}
  if(s.capabilities.wait){const next=await command({type:'wait'});assert.equal(next.status,200);report.next_wait_accepted=true;}
 }
 report.passed=true;
}catch(e){report.error=String(e.stack || e);process.exitCode=1;}
finally{report.lines=lines;await mkdir(dirname(output),{recursive:true});await writeFile(output,JSON.stringify(report,null,2));if(m)m.cwrap('tome_free',null,[])();console.log(JSON.stringify({output,mode,passed:report.passed,error:report.error?.slice(0,500),matches_user_prestate:report.matches_user_prestate,response_status:report.response_status}));}
