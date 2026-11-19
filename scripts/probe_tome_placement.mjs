// Real native placement and replay. No player actions or combat simulation.
import {readFile,writeFile,mkdir} from 'node:fs/promises';
import {resolve} from 'node:path';
import {pathToFileURL} from 'node:url';
import assert from 'node:assert/strict';
const root=resolve(process.argv[2]),out=resolve(process.argv[3]);
await mkdir(out,{recursive:true});
const identity=JSON.parse(await readFile(resolve(root,'identity.json'),'utf8'));
const publicRoot=resolve(root,'public');
const {createKernel}=await import(pathToFileURL(resolve(publicRoot,'kernel_runtime.mjs')));
const {BattleSession}=await import(pathToFileURL(resolve(publicRoot,'battle_session.mjs')));
const encounter=JSON.parse(await readFile(resolve(root,'encounter.json'),'utf8'));
const bytes=await readFile(resolve(publicRoot,'tome.data'));
const {default:createTome}=await import(pathToFileURL(resolve(publicRoot,'tome.js')));
const {installEncounter}=await import(pathToFileURL(resolve(publicRoot,'encounter_overlay.mjs')));
const logs=[];
// Node needs an explicit Wasm buffer; the generated loader otherwise uses fetch.
const wasm=await readFile(resolve(publicRoot,'tome.wasm'));
const open=()=>createKernel(createTome,{wasmBinary:wasm,getPreloadedPackage:()=>bytes.buffer.slice(bytes.byteOffset,bytes.byteOffset+bytes.byteLength)},
 {prepare:m=>installEncounter(m,encounter),log:(...x)=>{logs.push(x.join(' '));if(logs.length>30)logs.shift();}});
let kernel;
try{
 // Catalogue loading can instantiate prototypes. Like the host query endpoint,
 // inspect a disposable reconstruction and discard it before authoritative writes.
 kernel=await open();const disposable=new BattleSession(kernel.rpc,identity.build_id,encounter.seed);await disposable.init();
 const map=await kernel.rpc('scene_query',{include_tiles:true,source:'thieve'},disposable.bridge.generation);
 kernel.dispose();kernel=null;
 kernel=await open();const session=new BattleSession(kernel.rpc,identity.build_id,encounter.seed);
 const initial=await session.init(),turn=initial.turn;
 const query=()=>kernel.rpc('scene_query',{include_tiles:true},session.bridge.generation);
 assert.ok(map.enemy_catalog.some(e=>e.enemy_id==='thieve:THIEF_BANDIT'));
 await writeFile(resolve(out,'map.json'),JSON.stringify(map));
 const initialNative=await kernel.rpc('dm_inspect',{},session.bridge.generation);
 await writeFile(resolve(out,'initial-archive.json'),JSON.stringify(await session.suspend()));session.suspended=false;
 const count=()=>kernel.rpc('dm_inspect',{},session.bridge.generation).then(x=>x.enemies.length);
 const before=await count(),receipts=[];
 async function spawn(id,placement,extra={}){
  const result=await session.execute('dm_transition',{operation:'spawn_enemy',operation_id:id,enemy_id:'thieve:THIEF_BANDIT',placement,...extra});
  assert.equal(result.status,200);assert.equal(result.body.turn,turn);
  receipts.push(result.transition.transition);return result.transition.transition;
 }
 for(let i=0;i<4;i++){
  const r=await spawn('here-'+i,'same_room');assert.equal(r.status,'applied',JSON.stringify(r));
  if(map.room_mode!=='outdoor_visibility')assert.equal(r.room_id,map.player.room_id);
  else assert.equal(map.visibility[r.y][r.x],'p','same-area tile must be visible');
 }
 assert.equal(await count(),before+4);assert.equal(new Set(receipts.map(x=>x.actor_id)).size,4);
 const once=await spawn('here-0','same_room');assert.equal(once.actor_id,receipts[0].actor_id);assert.equal(await count(),before+4);
 const conflict=await spawn('here-0','other_room');assert.equal(conflict.reason,'operation_id_conflict');
 const otherExpected=map.room_mode==='outdoor_visibility'||map.rooms.some(r=>r.id!==map.player.room_id);
 for(let i=0;i<4;i++){
  const r=await spawn('else-'+i,'other_room');assert.equal(r.status,otherExpected?'applied':'rejected',JSON.stringify(r));
  if(r.status==='applied'&&map.room_mode!=='outdoor_visibility')assert.notEqual(r.room_id,map.player.room_id);
  if(r.status==='applied'&&map.room_mode==='outdoor_visibility')assert.equal(map.visibility[r.y][r.x],'.','elsewhere tile must remain unseen');
 }
 const fresh=await query();let point;
 for(let y=0;y<fresh.height&&!point;y++)for(let x=0;x<fresh.width;x++)if(fresh.tiles[y][x]==='.') {point={x,y};break;}
 assert.ok(point);const exact=await spawn('exact','exact',point);assert.equal(exact.status,'applied');assert.equal(exact.x,point.x);assert.equal(exact.y,point.y);
 const finalCount=await count();
 for(const [id,p]of [['occupied',point],['outside',{x:map.width,y:0}],['player',{x:map.player.x,y:map.player.y}]]){
  assert.equal((await spawn(id,'exact',p)).status,'rejected');assert.equal(await count(),finalCount);
 }
 // Restore every placement, including negative receipts, from the native event journal.
 const archive=await session.suspend(),native=await kernel.rpc('dm_inspect',{},session.bridge.generation);
 await writeFile(resolve(out,'archive.json'),JSON.stringify(archive));kernel.dispose();kernel=null;
 kernel=await open();const replay=await BattleSession.restore(kernel.rpc,identity.build_id,archive);
 const restored=await kernel.rpc('dm_inspect',{},replay.bridge.generation);
 assert.deepEqual(restored,native);assert.equal(replay.bridge.state().turn,turn);
 const summary={passed:true,kind:encounter.map.kind,room_mode:map.room_mode,rooms:map.rooms.length,initial_enemies:before,final_enemies:finalCount,turn,receipts,replay_equal:true};
 await writeFile(resolve(out,'summary.json'),JSON.stringify(summary,null,2));console.log(JSON.stringify(summary));
}catch(e){await writeFile(resolve(out,'failure.json'),JSON.stringify({error:String(e.stack),logs},null,2));throw e;}
finally{kernel?.dispose();}
