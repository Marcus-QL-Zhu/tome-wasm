// Experimental trusted-host process. A pending VM is never a committed cache.
import {readFile} from 'node:fs/promises';
import {createHash,randomBytes} from 'node:crypto';
import {resolve} from 'node:path';
import {pathToFileURL} from 'node:url';
import {createInterface} from 'node:readline';
import {canonical,digest} from '../tome_mvp/wasm/battle_session.mjs';
import {selectPartitions,verifyAuthorizedPartitions,protectedReferencesByOwner,normalizePartitionExport} from '../tome_mvp/wasm/partition_transport.mjs';
import {restorePartitionCandidate,reconstructHotIndex} from '../tome_mvp/wasm/partition_session_host.mjs';
import {buildPartitionCandidate} from './tome_partition_candidate.mjs';
import {createHotParent,hotCandidate} from '../tome_mvp/wasm/partition_hot_codec.mjs';

const eq=(a,b)=>canonical(a)===canonical(b);
const sha=b=>createHash('sha256').update(b).digest('hex');
const isText=x=>typeof x==='string' && x.length>0;
function boundary(session,native){
 const b=session.bridge,s=b.snapshot;
 if(session.nativeBoundary!=='campaign_admin' || b.boundary!=='decision' || b.locked || b.pending || b.authorized || b.navigation || s?.input_request || s?.area_outside!==true || s?.map_available!==false || !['idle','stopped'].includes(s?.ai_status) || native?.local_areas?.outside!==true)throw Error('resident requires mapless outside campaign boundary');
}
export function createPartitionResident({identityBytes,open,makeCandidate=buildPartitionCandidate,restore=restorePartitionCandidate}){
 const identity=JSON.parse(identityBytes.toString()),frozenIdentity=sha(identityBytes);let current=null,pending=null;
 function discard(){try{current?.kernel?.dispose();}finally{current=null;pending=null;}}
 async function request(req){
  try{
   if(req?.kind==='abort'){if(current && pending && req.pending_token===pending.lease.pending_token){try{await current.kernel.rpc('partition_abort',{pending_token:req.pending_token},current.session.bridge.generation);}catch{}}discard();return {ok:true,aborted:true};}
   if(req?.kind==='confirm'){
    if(!pending || !eq(req.lease,pending.lease))throw Error('resident lease mismatch');
    const l=pending.lease,{session,kernel}=current;
    const ack=await kernel.rpc('partition_confirm',{pending_token:l.pending_token,scope:l.scope,parent_version:l.parent_version,parent_manifest_sha256:l.parent_manifest_sha256,new_version:l.new_version,new_manifest_sha256:l.new_manifest_sha256,hot_sha256:l.hot_sha256},session.bridge.generation);
    if(ack?.confirmed!==true || ack.version!==l.new_version || ack.manifest_sha256!==l.new_manifest_sha256)throw Error('native confirmation mismatch');
    session.events=[];current.archive=structuredClone(pending.archive);current.parent=pending.parent;pending=null;
    return {ok:true,confirmed:true,version:l.new_version,manifest_sha256:l.new_manifest_sha256};
   }
   if(!['prepare','prepare_hot'].includes(req?.kind) || pending)throw Error('resident request unavailable');
   const compact=req.kind==='prepare_hot',bind=req.binding;
   if(compact && (!current?.parent || !bind || !eq(Object.keys(bind).sort(),['db_identity','envelope_sha256','frozen_identity','hot_sha256','manifest_sha256','scope','version']) || !Object.keys(req).every(k=>['kind','binding','archive','operations','request_id','expected_final'].includes(k))))throw Error('confirmed resident parent required');
   const {archive,operations,request_id}=req;
   const scope=compact?{build:bind.scope?.build,world_id:bind.scope?.world_id,campaign_id:bind.scope?.campaign_id}:req.scope;
   const battle_id=compact?bind.scope?.battle_id:req.battle_id,db_identity=compact?bind.db_identity:req.db_identity,version=compact?bind.version:req.version;
   const {manifest,blobs,selection,delta_events}=req;
   if(compact && (!eq(bind.scope,current.binding.scope) || !eq(bind.db_identity,current.binding.db_identity) || bind.frozen_identity!==frozenIdentity || version!==current.archive.base.version || bind.manifest_sha256!==current.archive.base.manifest_sha256 || bind.hot_sha256!==current.parent.meta.hot_root.blob_digest || bind.envelope_sha256!==await digest(current.archive.base.envelope) || !eq(archive,current.archive)))throw Error('resident compact binding mismatch');
   if(!isText(battle_id) || !isText(request_id) || !db_identity || !eq(Object.keys(db_identity).sort(),['device','inode','instance_id','path']) || !isText(db_identity.path) || !isText(db_identity.instance_id) || !Number.isSafeInteger(version) || version<1 || !scope || !['build','world_id','campaign_id'].every(k=>isText(scope[k])) || scope.build!==identity.build_id || archive?.format!=='tome-partition-session-v1' || archive.build!==scope.build || archive.base?.version!==version || !compact && archive.base?.manifest_sha256!==await digest(manifest) || archive.final!==archive.base.envelope?.final || archive.base.envelope?.native_boundary!=='campaign_admin' || !Array.isArray(archive.audit) || !Array.isArray(archive.events) || archive.events.length || !compact && (!Array.isArray(delta_events) || delta_events.length) || !Array.isArray(operations) || operations.length!==2 || operations[0]?.operation!=='campaign_items' || !['equip','unequip','switch_set','progression'].includes(operations[0]?.request?.operation) || operations[1]?.operation!=='campaign_reconcile' || operations.some(o=>o.world_id!==scope.world_id))throw Error('invalid resident baseline or operation');
   const ids=compact?['hot']:selectPartitions(manifest,scope,selection);
   if(!compact){if(selection?.kind!=='loadout' || !eq(ids,['hot']) || !blobs || !eq(Object.keys(blobs),['hot']))throw Error('resident requires exactly hot');await verifyAuthorizedPartitions(manifest,scope,ids,blobs);}
   const fullScope={build:scope.build,world_id:scope.world_id,campaign_id:scope.campaign_id,battle_id};
   const binding={scope:fullScope,db_identity,frozen_identity:frozenIdentity};
   if(current && (!eq(current.binding,binding) || !eq(current.archive,archive)))throw Error('resident baseline mismatch');
   const warm_hit=!!current;
   if(!current){
    const kernel=await open();current={kernel,binding,archive:structuredClone(archive)};
    current.session=await restore(kernel.rpc,scope.build,archive.seed,scope,archive.base.envelope,manifest,ids,blobs,{...fullScope,version,manifest_sha256:archive.base.manifest_sha256});
   }
   const {session,kernel}=current;
   if(!warm_hit)boundary(session,await kernel.rpc('dm_inspect',{},session.bridge.generation));
   if(req.expected_final!==undefined && req.expected_final!==await digest(session.bridge.state()))throw Error('resident final mismatch');
   const token=randomBytes(32).toString('hex');
   let hotOutput;
   const result=await makeCandidate({session,kernel,scope,prior:manifest,residentIds:ids,operations,priorAudit:archive.audit,nextVersion:version+1,inspectBeforeExport:true,exportCandidate:async(s,sc,prior,residentIds,nativeBefore)=>{
    boundary(s,nativeBefore);
    const out=await kernel.rpc('partition_prepare',{pending_token:token,scope:fullScope,parent_version:version,parent_manifest_sha256:archive.base.manifest_sha256,operation_id:request_id,protected_by_owner:compact?current.parent.protectedByOwner:protectedReferencesByOwner(prior,sc,residentIds),index_mode:'hot-delta-v1'},s.bridge.generation);
    if(out?.pending_token!==token)throw Error('native pending token mismatch');
    if(compact){hotOutput=hotCandidate(current.parent,sc,out,s.bridge.generation);return {manifest_sha256:hotOutput.manifest_sha256,native_boundary:out.native_boundary};}
    return {...await normalizePartitionExport(sc,prior,reconstructHotIndex(prior,sc,out),s.bridge.generation),native_boundary:out.native_boundary};
   }});
   boundary(session,result.candidate.native);
   const next=result.candidate.archive;
   const parentHot=compact?current.parent.meta.hot_root.blob_digest:manifest.hot_root.blob_digest;
   const lease={pending_token:token,scope:fullScope,parent_version:version,parent_manifest_sha256:archive.base.manifest_sha256,parent_hot_sha256:parentHot,parent_envelope_sha256:await digest(archive.base.envelope),new_version:version+1,new_manifest_sha256:next.base.manifest_sha256,hot_sha256:compact?hotOutput.nextParent.meta.hot_root.blob_digest:result.candidate.manifest.hot_root.blob_digest,new_envelope_sha256:await digest(next.base.envelope),frozen_identity:frozenIdentity,db_identity:structuredClone(db_identity),request_id};
   pending={lease,archive:structuredClone(next),parent:compact?hotOutput.nextParent:createHotParent(result.candidate.manifest,scope)};
   if(compact)return {ok:true,warm_hit:true,candidate:{...hotOutput.compact,archive:next,view:result.candidate.view,native:result.candidate.native},results:result.results,lease};
   return {ok:true,...result,lease,warm_hit};
  }catch(e){discard();return {ok:false,error:String(e?.message||e)};}
 }
 return {request,dispose:discard};
}

async function main(){
 const root=resolve(process.argv[2]);const identityBytes=await readFile(resolve(root,'../identity.json'));
 const identity=JSON.parse(identityBytes),{createKernel}=await import(pathToFileURL(resolve(root,'kernel_runtime.mjs'))),{default:create}=await import(pathToFileURL(resolve(root,'tome.js')));
 const bytes=await readFile(resolve(root,'tome.data')),wasmBinary=await readFile(resolve(root,'tome.wasm'));
 const encounter=identity.encounter_overlay?JSON.parse(await readFile(resolve(root,'encounter.json'),'utf8')):null;
 const install=encounter?(await import(pathToFileURL(resolve(root,'encounter_overlay.mjs')))).installEncounter:null;
 // Do not retain arbitrary engine output: structured messages and long encoded
 // strings can contain payloads. Preserve only a bounded diagnostic summary.
 let firstError=null,tail=[];
 const log=(...args)=>{const raw=args.map(String).join(' ');const safe=raw.replace(/\{.*|\[.*|(?:[A-Za-z0-9+/=_-]{40,})/g,'[redacted]').replace(/(secret|token|password|authorization|key)\s*[:=]\s*\S+/gi,'$1=[redacted]').slice(0,300);if(/error|fail|unknown/i.test(safe) && firstError===null)firstError=safe;tail.push(safe);if(tail.length>8)tail.shift();};
 const controller=createPartitionResident({identityBytes,open:()=>createKernel(create,{wasmBinary,getPreloadedPackage:()=>bytes.buffer.slice(bytes.byteOffset,bytes.byteOffset+bytes.byteLength)},{prepare:install?m=>install(m,encounter):undefined,log,fail:code=>log('native error code:',String(code).replace(/[^a-zA-Z0-9_-]/g,'').slice(0,80))})});
 const lines=createInterface({input:process.stdin,crlfDelay:Infinity});
 try{for await(const line of lines){let id=null,result;try{if(Buffer.byteLength(line)>80*1024*1024)throw Error('request exceeds capacity');const message=JSON.parse(line);id=message.id;result=await controller.request(message.request);}catch(e){controller.dispose();result={ok:false,error:String(e?.message||e)};}if(result.ok!==true)result.logs={first_error:firstError,tail};process.stdout.write(JSON.stringify({id,result})+'\n');}}finally{controller.dispose();}
}
if(process.argv[1] && import.meta.url===pathToFileURL(resolve(process.argv[1])).href)main().catch(e=>{process.stderr.write(String(e)+'\n');process.exitCode=1;});
