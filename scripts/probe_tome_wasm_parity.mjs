// Same prepared rules, seed, controller and command stream on native and Wasm.
import {readFile,writeFile} from 'node:fs/promises';
import {resolve} from 'node:path';
import {pathToFileURL} from 'node:url';
import {spawn} from 'node:child_process';
import {createInterface} from 'node:readline';
import {EngineBridge} from '../tome_mvp/wasm/engine_bridge.mjs';
const base=resolve(process.argv[2]||'artifacts/tome-wasm-20261111/mvp');
const out=resolve(process.argv[3]||'artifacts/tome-wasm-20261111/parity.json');
const config=JSON.parse(await readFile(resolve(base,'native_config.json'),'utf8'));
const child=spawn(config.worker_argv[0],config.worker_argv.slice(1),{windowsHide:true,stdio:['pipe','pipe','pipe']});
let pending,stderr='';
child.stderr.on('data',b=>{stderr=(stderr+b.toString()).slice(-16384)});
child.on('exit',code=>pending?.reject(Error(`native exit ${code}: ${stderr}`)));
createInterface({input:child.stdout}).on('line',line=>{if(pending){const p=pending;pending=null;p.resolve(line)}});
let nativeId=0,wasmId=0,mod;
const data=await readFile(resolve(base,'public/tome.data'));
const {default:createTome}=await import(pathToFileURL(resolve(base,'public/tome.js')));
const marks=[],differences=[];
function diff(a,b,path='') {
 if(typeof a==='number'&&typeof b==='number')return Math.abs(a-b)<=1e-7*Math.max(1,Math.abs(a),Math.abs(b))?null:{path,native:a,wasm:b};
 if(a===b)return null;
 if(a==null||b==null||typeof a!==typeof b)return {path,native:a,wasm:b};
 if(typeof a!=='object')return {path,native:a,wasm:b};
 const keys=[...new Set([...Object.keys(a),...Object.keys(b)])].sort();
 for(const key of keys){const d=diff(a[key],b[key],`${path}/${key}`);if(d)return d;}return null;
}
function decode(raw,id){const r=JSON.parse(raw);if(r.id!==id)throw Error('request identity mismatch');if(r.ok)return r.result;const e=Error(r.error.code);e.outcome=r.error.outcome;throw e;}
async function nrpc(method,params={},gen){const q={protocol:'tome-headless-v1',id:++nativeId,method,params};if(gen!=null)q.expected_generation=gen;const raw=await new Promise((resolve,reject)=>{const timer=setTimeout(()=>reject(Error('native timeout')),60000);pending={resolve:v=>{clearTimeout(timer);resolve(v)},reject:e=>{clearTimeout(timer);reject(e)}};child.stdin.write(JSON.stringify(q)+'\n')});return decode(raw,nativeId);}
try {
 mod=await createTome({wasmBinary:await readFile(resolve(base,'public/tome.wasm')),getPreloadedPackage:()=>data.buffer.slice(data.byteOffset,data.byteOffset+data.byteLength),print:()=>{},printErr:()=>{}});
 const init=mod.cwrap('tome_init','number',[]),send=mod.cwrap('tome_request','number',['string']),result=mod.cwrap('tome_result','string',[]);
 if(init()!==0)throw Error(result());
 const wrpc=async(method,params={},gen)=>{const q={protocol:'tome-headless-v1',id:++wasmId,method,params};if(gen!=null)q.expected_generation=gen;if(send(JSON.stringify(q))!==0)throw Error(result());return decode(result(),wasmId)};
 const n=new EngineBridge(nrpc),w=new EngineBridge(wrpc);
 let ns=await n.init(12),ws=await w.init(12);
 function compare(label){const d=diff(ns,ws);marks.push({label,native_turn:ns.turn,wasm_turn:ws.turn,equal:!d});if(d){for(const key of [...new Set([...Object.keys(ns),...Object.keys(ws)])]){const item=diff(ns[key],ws[key],`/${key}`);if(item)differences.push(item);}throw Error(`public-state mismatch ${label}: ${d.path}`)}}
 compare('create');
 async function cmd(p){const t=performance.now();const a=await n.command({...p,revision:ns.revision});const nt=performance.now()-t;const t2=performance.now();const b=await w.command({...p,revision:ws.revision});const wt=performance.now()-t2;if(a.status!==200||b.status!==200)throw Error(JSON.stringify({p,a,b}));ns=a.body;ws=b.body;compare(p.type);Object.assign(marks.at(-1),{native_ms:nt,wasm_ms:wt});}
 for(let i=0;i<3;i++)await cmd({type:'wait'});
 await cmd({type:'talent',talent:'T_DWARF_RESILIENCE'});
 const h=ns.party.find(p=>p.id===ns.control_actor_id);
 const move=[[0,-1],[0,1],[-1,0],[1,0]].find(([dx,dy])=>ns.map[h.y+dy]?.[h.x+dx]==='.');
 if(move)await cmd({type:'move',dx:move[0],dy:move[1]});
 await cmd({type:'ai_config',stop_on_rare:false,stop_enemy_count:0,talent_weights:Object.fromEntries(ns.ai_config.talents.map(t=>[t.id,t.multiplier]))});
 await cmd({type:'ai_start',budget:40});
 for(let i=0;i<40&&ns.capabilities.ai_step;i++)await cmd({type:'ai_step',control_epoch:ns.control_epoch});
 await cmd({type:'pause'});
 await cmd({type:'new_game',seed:12});
 await writeFile(out,JSON.stringify({ok:true,scope:'complete published observations; number tolerance 1e-7; identical single-observe controller',marks,differences},null,2));
 console.log(JSON.stringify({ok:true,boundaries:marks.length,out}));
} catch(e){await writeFile(out,JSON.stringify({ok:false,error:String(e),marks,differences,stderr},null,2));console.error(String(e));process.exitCode=1;}
finally{if(mod)mod.cwrap('tome_free',null,[])();child.kill();}
