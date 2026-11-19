// Real Wasm probe. This imports the compiled module; no battle substitute.
import {readFile,writeFile,mkdir} from 'node:fs/promises';
import {resolve,dirname} from 'node:path';
import {pathToFileURL} from 'node:url';
import assert from 'node:assert/strict';
import {EngineBridge} from '../tome_mvp/wasm/engine_bridge.mjs';

const root=resolve(process.argv[2] || 'artifacts/tome-wasm-20261111/mvp/public');
const output=resolve(process.argv[3] || 'artifacts/tome-wasm-20261111/real-probe.json');
const logs=[];
const {default:createTome}=await import(pathToFileURL(resolve(root,'tome.js')));
const data=await readFile(resolve(root,'tome.data'));
const started=performance.now();
const mod=await createTome({wasmBinary:await readFile(resolve(root,'tome.wasm')),getPreloadedPackage:()=>data.buffer.slice(data.byteOffset,data.byteOffset+data.byteLength),print:s=>{if(logs.length<500)logs.push(s)},printErr:s=>{if(logs.length<500)logs.push(s)}});
const init=mod.cwrap('tome_init','number',[]),send=mod.cwrap('tome_request','number',['string']),result=mod.cwrap('tome_result','string',[]);
assert.equal(init(),0,result());
let seq=0;
const receipts=[];
const rpc=async(method,params={},generation)=>{
 const req={protocol:'tome-headless-v1',id:++seq,method,params};
 if(generation!=null)req.expected_generation=generation;
 const t=performance.now(),rc=send(JSON.stringify(req)),raw=result();
 assert.equal(rc,0,`native error: ${raw}`);
 const r=JSON.parse(raw);
 assert.equal(r.id,seq);receipts.push({method,ms:performance.now()-t,ok:r.ok});
 if(r.ok)return r.result;
 const e=Error(r.error.code);e.outcome=r.error.outcome;throw e;
};
const b=new EngineBridge(rpc);
let s=await b.init(12);
const initMs=performance.now()-started;
assert.equal(s.map.length,20);assert.ok(s.map.every(r=>r.length===20));assert.equal(s.party.length,3);
const initial=structuredClone(s);
await mkdir(dirname(output),{recursive:true});
await writeFile(output.replace(/\.json$/,'.initial.json'),JSON.stringify(initial));
const steps=[];
async function command(p){const t=performance.now(),r=await b.command({...p,revision:s.revision});assert.equal(r.status,200,JSON.stringify(r.body));s=r.body;steps.push({type:p.type,ms:performance.now()-t,turn:s.turn,status:s.status,ai:s.ai_status,stop:s.ai_stop_reason,revision:s.revision});return s;}
for(let i=0;i<3;i++)await command({type:'wait'});
const hero=s.party.find(p=>p.id===s.control_actor_id);
const move=[[0,-1],[0,1],[-1,0],[1,0]].find(([dx,dy])=>s.map[hero.y+dy]?.[hero.x+dx]==='.');
if(move)await command({type:'move',dx:move[0],dy:move[1]});
await command({type:'pause'});
const weights=Object.fromEntries(s.ai_config.talents.map(t=>[t.id,t.multiplier]));
await command({type:'ai_config',stop_on_rare:false,stop_enemy_count:0,talent_weights:weights});
await command({type:'ai_start',budget:500});
for(let i=0;i<500 && s.ai_status==='running' && s.capabilities.ai_step;i++)await command({type:'ai_step',control_epoch:s.control_epoch});
// Explicitly stop and reset only this probe's private instance.
if(s.capabilities.pause)await command({type:'pause'});
const end=structuredClone(s);
await command({type:'new_game',seed:12});
assert.equal(s.generation,2);assert.equal(s.turn,0);assert.equal(s.map.length,20);
const evidence={runtime:'real WebAssembly under Node',initialization_ms:initMs,initial:{turn:initial.turn,map:[20,20],party:initial.party.map(p=>({name:p.name,hp:p.hp,max_hp:p.max_hp,x:p.x,y:p.y}))},final:{turn:end.turn,status:end.status,mission_complete:end.mission_complete,ai_stop_reason:end.ai_stop_reason,party:end.party.map(p=>({name:p.name,hp:p.hp,down:p.down})),visible_enemies:end.enemies.length},reset:{generation:s.generation,turn:s.turn},steps,receipts,logs};
await writeFile(output,JSON.stringify(evidence,null,2));
await writeFile(output.replace(/\.json$/,'.final.json'),JSON.stringify(end));
console.log(JSON.stringify({init_ms:initMs,final:evidence.final,reset:evidence.reset,steps:steps.length,output}));
mod.cwrap('tome_free',null,[])();
