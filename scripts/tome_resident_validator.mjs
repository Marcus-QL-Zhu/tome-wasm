// Trusted local pipe only. The caller supplies the server's committed archive.
// Memory is disposable: a failed request drops the VM; disk remains authoritative.
import {readFile} from 'node:fs/promises';
import {resolve} from 'node:path';
import {pathToFileURL} from 'node:url';
import {createInterface} from 'node:readline';
import {validateOperations} from './tome_validate_operations.mjs';
const root=resolve(process.argv[2]);
const identity=JSON.parse(await readFile(resolve(root,'../identity.json'),'utf8'));
const {createKernel}=await import(pathToFileURL(resolve(root,'kernel_runtime.mjs')));
const {BattleSession,canonical}=await import(pathToFileURL(resolve(root,'battle_session.mjs')));
const {default:createTome}=await import(pathToFileURL(resolve(root,'tome.js')));
const data=await readFile(resolve(root,'tome.data'));
const wasmBinary=await readFile(resolve(root,'tome.wasm'));
const encounter=identity.encounter_overlay?JSON.parse(await readFile(resolve(root,'encounter.json'),'utf8')):null;
const install=encounter?(await import(pathToFileURL(resolve(root,'encounter_overlay.mjs')))).installEncounter:null;
let kernel=null,session=null,lastArchive=null,lastUsed=Date.now();
const logs=[];
const dispose=()=>{kernel?.dispose();kernel=null;session=null;lastArchive=null;};
async function validate(request){
 const reused=Boolean(session && lastArchive===canonical(request.archive));
 if(!reused){
  dispose();
  kernel=await createKernel(createTome,{wasmBinary,getPreloadedPackage:()=>data.buffer.slice(data.byteOffset,data.byteOffset+data.byteLength)},
   {prepare:install?m=>install(m,encounter):undefined,log:(...x)=>{logs.push(x.join(' '));if(logs.length>20)logs.shift();}});
  session=await BattleSession.restore(kernel.rpc,identity.build_id,request.archive);
 }
 const operations=request.operations || [];
 const hasQuery=operations.some(op=>op.operation==='scene_query');
 if(hasQuery && operations.some(op=>op.operation!=='scene_query'))throw Error('scene queries must not be mixed with mutations');
 const result=await validateOperations(session,kernel,request);
 // Querying a native catalog may instantiate prototypes and consume UIDs.
 // The archive is unchanged, but this VM is no longer a valid cache entry.
 if(hasQuery)dispose();
 else{lastArchive=canonical(result.archive);lastUsed=Date.now();}
 return {...result,reused_runtime:reused};
}
// Expire even when there is no next request. Never retain every visited scene VM.
const timer=setInterval(()=>{if(kernel && Date.now()-lastUsed>120000)dispose();},10000);timer.unref();
try{
 for await(const line of createInterface({input:process.stdin,crlfDelay:Infinity})){
  let id=null,result;
  try{
   if(Buffer.byteLength(line,'utf8')>80*1024*1024)throw Error('validator input too large');
   const doc=JSON.parse(line);id=doc.id;
   if(!Number.isSafeInteger(id) || !doc.request?.archive)throw Error('invalid validation envelope');
   result=await validate(doc.request);
  }catch(e){dispose();result={ok:false,error:String(e.stack || e).slice(0,6000),logs:logs.slice()};}
  process.stdout.write(JSON.stringify({id,result})+'\n');
 }
}finally{clearInterval(timer);dispose();}
