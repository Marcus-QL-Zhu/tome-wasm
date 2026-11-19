// Server-side validation uses the exact browser Wasm package, not client claims.
import {readFile,writeFile} from 'node:fs/promises';
import {resolve} from 'node:path';
import {pathToFileURL} from 'node:url';
import {createHash} from 'node:crypto';
import {fileURLToPath} from 'node:url';
const root=resolve(process.argv[2]),input=resolve(process.argv[3]),output=resolve(process.argv[4]);
const {createKernel}=await import(pathToFileURL(resolve(root,'kernel_runtime.mjs')));
const {BattleSession}=await import(pathToFileURL(resolve(root,'battle_session.mjs')));
const request=JSON.parse(await readFile(input,'utf8')),identity=JSON.parse(await readFile(resolve(root,'../identity.json'),'utf8'));
if(identity.encounter_overlay && identity.inputs?.host_validator_sha256){
 const actual=createHash('sha256').update(await readFile(fileURLToPath(import.meta.url))).digest('hex');
 if(identity.inputs?.host_validator_sha256!==actual)throw Error('frozen host validator mismatch');
 const helperHash=createHash('sha256').update(await readFile(new URL('./tome_validate_operations.mjs',import.meta.url))).digest('hex');
 if(identity.inputs?.host_validator_operations_sha256!==helperHash)throw Error('frozen validator operations mismatch');
}
let kernel;const logs=[];
try{
 const {default:createTome}=await import(pathToFileURL(resolve(root,'tome.js')));const bytes=await readFile(resolve(root,'tome.data'));
 const encounter=identity.encounter_overlay?JSON.parse(await readFile(resolve(root,'encounter.json'),'utf8')):null;
 const installEncounter=encounter?(await import(pathToFileURL(resolve(root,'encounter_overlay.mjs')))).installEncounter:null;
 kernel=await createKernel(createTome,{wasmBinary:await readFile(resolve(root,'tome.wasm')),getPreloadedPackage:()=>bytes.buffer.slice(bytes.byteOffset,bytes.byteOffset+bytes.byteLength)},{prepare:encounter?m=>installEncounter(m,encounter):undefined,log:(...x)=>{logs.push(x.join(' '));if(logs.length>40)logs.shift();}});
 const session=await BattleSession.restore(kernel.rpc,identity.build_id,request.archive);
 const {validateOperations}=await import(new URL('./tome_validate_operations.mjs',import.meta.url));
 const validated=await validateOperations(session,kernel,request);
 await writeFile(output,JSON.stringify(validated));
 console.log(JSON.stringify({ok:true,events:validated.archive.events.length,turn:session.bridge.state().turn}));
}catch(e){await writeFile(output,JSON.stringify({ok:false,error:String(e.stack || e).slice(0,12000),logs}));process.exitCode=1;}
finally{kernel?.dispose();}
