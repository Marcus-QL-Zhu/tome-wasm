import {readFile,writeFile,mkdir} from 'node:fs/promises';
import {resolve,dirname} from 'node:path';
import {pathToFileURL} from 'node:url';
import {createHash} from 'node:crypto';
import assert from 'node:assert/strict';
const root=resolve(process.argv[2]),output=resolve(process.argv[3]);
const {createKernel}=await import(pathToFileURL(resolve(root,'kernel_runtime.mjs')));
const {BattleSession,canonical}=await import(pathToFileURL(resolve(root,'battle_session.mjs')));
const {default:createTome}=await import(pathToFileURL(resolve(root,'tome.js')));
const bytes=await readFile(resolve(root,'tome.data')),wasmBinary=await readFile(resolve(root,'tome.wasm')),identity=JSON.parse(await readFile(resolve(root,'../identity.json')));
async function make(observeNative){
 const privateHashes=[],features=[],logs=[];let lastView;
 const k=await createKernel(async options=>{
  const m=await createTome(options);
  if(observeNative){
   const path='/bundle/headless/worker.lua',source=m.FS.readFile(path,{encoding:'utf8'});
   const probe=String.raw`
    local native_json=require('json_validate')
    local md5=require('md5')
    assert(md5.sumhexa('abc')=='900150983cd24fb0d6963f7d28e17f72')
    assert(mime.b64('abc')=='YWJj')
    local p=state.player;local trees=native_json.object({})
    for id,v in pairs(p.talents_types)do if v then trees[id]=true end end
    local r=rng.state_get();r.words=native_json.array(r.words)
    print('WANDERER_PRIVATE:'..native_json.encode(native_json.object({rng=native_json.object(r),seed=p.randventurer_seed,trees=trees,level=p.level,custom_pending=not not p.custom_birthend})))
   `;
   m.FS.writeFile(path,source.replace('local function observe()','local function observe()\n'+probe));
  }
  return m;
 },{wasmBinary,getPreloadedPackage:()=>bytes.buffer.slice(bytes.byteOffset,bytes.byteOffset+bytes.byteLength)},{observe:v=>{lastView=structuredClone(v);},log:(...v)=>{const line=v.join(' ');if(line.startsWith('WANDERER_PRIVATE:')){const value=JSON.parse(line.slice(17));privateHashes.push(createHash('sha256').update(canonical(value)).digest('hex'));features.push({seed:value.seed,trees:value.trees,level:value.level,custom_pending:value.custom_pending});}logs.push(line);if(logs.length>18)logs.shift();}});
 return {k,privateHashes,features,logs,view:()=>lastView};
}
const report={runtime:'real Wasm',build:identity.build_id,geometry_override:false,native_rule_override:false};
let first,second,witnessA,witnessB;
try{
 first=await make(false);const s=new BattleSession(first.k.rpc,identity.build_id,23);await s.init();
 for(let i=0;i<20;i++)assert.equal((await s.execute('command',{type:'wait',revision:s.bridge.revision})).status,200);
 const archive=await s.suspend();await mkdir(dirname(output),{recursive:true});await writeFile(output+'.archive.json',JSON.stringify({archive}));
 second=await make(false);const restored=await BattleSession.restore(second.k.rpc,archive.build,archive);assert.deepEqual(restored.bridge.state(),s.bridge.state());s.suspended=false;
 for(let i=0;i<10;i++){const cmd={type:'wait',revision:s.bridge.revision};assert.deepEqual(await s.execute('command',cmd),await restored.execute('command',cmd));}
 report.unmodified_package_replay_identical=true;report.future_commands_identical=10;report.saved_events=archive.events.length;
 // Independent instrumented pair. Extra Lua allocations are not assumed to be
 // behavior-neutral: never admit this archive as an unmodified package save.
 witnessA=await make(true);const a=new BattleSession(witnessA.k.rpc,'instrumented-wanderer',23);await a.init();
 const feature=witnessA.features[0];assert.ok(feature.seed);assert.equal(feature.custom_pending,false);assert.equal(feature.level,18);assert.ok(Object.keys(feature.trees).length>=4);
 assert.equal(feature.seed.split('-').slice(1).join('-'),createHash('md5').update('tome-1.7.6').digest('base64'));
 for(let i=0;i<20;i++)assert.equal((await a.execute('command',{type:'wait',revision:a.bridge.revision})).status,200);
 const observedArchive=await a.suspend();witnessB=await make(true);const b=await BattleSession.restore(witnessB.k.rpc,observedArchive.build,observedArchive);assert.deepEqual(b.bridge.state(),a.bridge.state());assert.deepEqual(witnessB.privateHashes,witnessA.privateHashes);
 report.passed=true;report.native_md5_mime_vectors=true;report.native_fingerprint=true;report.native_birth=feature;report.instrumented_private_rng_replay_identical=true;report.instrumented_private_hashes=witnessA.privateHashes;report.instrumented_vs_plain_parity_verified=false;
}catch(e){report.error=String(e.stack||e);report.logs=first?.logs;process.exitCode=1;}
finally{first?.k.dispose();second?.k.dispose();witnessA?.k.dispose();witnessB?.k.dispose();await mkdir(dirname(output),{recursive:true});await writeFile(output,JSON.stringify(report,null,2));console.log(JSON.stringify({...report,instrumented_private_hashes:undefined,logs:undefined,error:report.error?.slice(-1800)}));}
