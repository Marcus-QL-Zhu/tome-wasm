import {readFile,writeFile,mkdir} from 'node:fs/promises';
import {resolve,dirname} from 'node:path';
import {pathToFileURL} from 'node:url';
import assert from 'node:assert/strict';
const root=resolve(process.argv[2]),output=resolve(process.argv[3]);
const {createKernel}=await import(pathToFileURL(resolve(root,'kernel_runtime.mjs')));
const {BattleSession}=await import(pathToFileURL(resolve(root,'battle_session.mjs')));
const {default:createTome}=await import(pathToFileURL(resolve(root,'tome.js')));
const bytes=await readFile(resolve(root,'tome.data')),wasmBinary=await readFile(resolve(root,'tome.wasm')),identity=JSON.parse(await readFile(resolve(root,'../identity.json'))),kernels=[],logs=[],report={runtime:'real frozen Wasm',fixture_override:false,explicit_test_continues:0};
async function make(){const k=await createKernel(createTome,{wasmBinary,getPreloadedPackage:()=>bytes.buffer.slice(bytes.byteOffset,bytes.byteOffset+bytes.byteLength)},{log:(...x)=>{logs.push(x.join(' '));if(logs.length>20)logs.shift();}});kernels.push(k);return k;}
try{
 const first=await make(),session=new BattleSession(first.rpc,identity.build_id,Number(process.argv[4] || 23));await session.init();let waits=0;
 for(let i=0;i<1600;i++){
  const s=session.bridge.state();if(['victory','defeat'].includes(s.status))break;report.last={turn:s.turn,status:s.status,stop:s.ai_stop_reason,control:s.control_actor_id,party:s.party.map(a=>({id:a.id,hp:a.hp,down:a.down}))};
  let body;
  if(s.down_events?.length)body={type:'confirm_down',generation:s.generation,event_id:s.down_events[0].id};
  else if(s.advance_status==='pending')body={type:'continue_pending'};
  else if(s.party.find(a=>a.id===s.control_actor_id)?.down && s.capabilities.takeover){const ally=s.party.find(a=>!a.down&&!a.dead);assert.ok(ally);body={type:'takeover',target:String(ally.id)};report.takeover=(report.takeover || 0)+1;}
  else if(s.rescue_progress && s.capabilities.rescue_step)body={type:'rescue_step',control_epoch:s.control_epoch};
  else if(s.status==='pending_rescue'){
   const actor=s.party.find(a=>a.id===s.control_actor_id),target=s.party.find(a=>a.down);assert.ok(actor && target);
   if(Math.max(Math.abs(actor.x-target.x),Math.abs(actor.y-target.y))===1)body={type:'rescue_start',target:String(target.id)};
   else{
    const rows=s.explored_map,queue=[[actor.x,actor.y]],paths=new Map([[actor.x+','+actor.y,null]]);let next;
    for(let j=0;j<queue.length;j++){const [x,y]=queue[j];if(Math.max(Math.abs(x-target.x),Math.abs(y-target.y))===1){next=[x,y];break;}
     for(const [dx,dy] of [[1,0],[-1,0],[0,1],[0,-1],[1,1],[-1,1],[1,-1],[-1,-1]]){const nx=x+dx,ny=y+dy,key=nx+','+ny;if(!paths.has(key)&&rows[ny]?.[nx]&&![' ','#'].includes(rows[ny][nx])&&!(nx===target.x&&ny===target.y)){paths.set(key,[x,y]);queue.push([nx,ny]);}}
    }
    assert.ok(next,'no explored rescue approach');while(paths.get(next.join(','))?.join(',')!==actor.x+','+actor.y)next=paths.get(next.join(','));body={type:'move',dx:next[0]-actor.x,dy:next[1]-actor.y};
   }
  }
  else if(s.ai_status==='running')body=s.capabilities.ai_renew?{type:'ai_renew',budget:500,control_epoch:s.control_epoch}:s.ai_remaining>0 && s.capabilities.ai_step?{type:'ai_step',control_epoch:s.control_epoch}:{type:'pause'};
  else if(s.capabilities.ai_start && report.explicit_test_continues<16){body={type:'ai_start',mode:'sweep',budget:500,continuous:true};report.explicit_test_continues++;}
  else if(s.capabilities.wait && waits++<60)body={type:'wait'};
  else throw Error('bounded driver cannot continue '+s.status+' / '+s.ai_stop_reason);
  const r=await session.execute('command',{...body,revision:s.revision});assert.equal(r.status,200,JSON.stringify(r));
 }
 const final=session.bridge.state();report.final={turn:final.turn,status:final.status,mission_complete:final.mission_complete,party:final.party.map(a=>({name:a.name,hp:a.hp,down:a.down})),visible_enemies:final.enemies.length};
 assert.ok(['victory','defeat'].includes(final.status),'natural run has not reached a terminal state');
 const archive=await session.suspend(),second=await make(),restored=await BattleSession.restore(second.rpc,identity.build_id,archive);assert.deepEqual(restored.bridge.state(),session.bridge.state());
 report.events=archive.events.length;report.terminal_restore_identical=true;report.passed=true;await writeFile(output.replace(/\.json$/,'.archive.json'),JSON.stringify(archive));
}catch(e){report.error=String(e.stack || e);process.exitCode=1;}
finally{for(const k of kernels)k.dispose();report.logs=logs;await mkdir(dirname(output),{recursive:true});await writeFile(output,JSON.stringify(report,null,2));console.log(JSON.stringify({...report,logs:undefined}));}
