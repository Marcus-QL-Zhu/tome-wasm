import {executeNativeOperations} from './tome_validate_operations.mjs';
import {exportPartitionCandidate,partitionSessionEnvelope} from '../tome_mvp/wasm/partition_session_host.mjs';
import {digest} from '../tome_mvp/wasm/battle_session.mjs';
// Experimental server-only helper. All inputs come from the locked server
// version. Its VM must be disposed after export, whether commit succeeds or not.
export async function buildPartitionCandidate({session,kernel,scope,prior,residentIds,operations,priorAudit,nextVersion,exportCandidate=exportPartitionCandidate,inspectBeforeExport=false}){
 if(!Array.isArray(operations) || !Array.isArray(priorAudit) || !Number.isSafeInteger(nextVersion) || nextVersion<1 || !session?.partitionOnly)throw Error('invalid trusted partition request');
 if(operations.some(op=>op.operation==='scene_query'))throw Error('query must use a disposable read-only VM');
 const eventStart=session.events.length;
 const results=await executeNativeOperations(session,kernel,{operations});
 const b=session.bridge;
 const adminLoadout=session.nativeBoundary==='campaign_admin' && operations.every(op=>['campaign_items','campaign_reconcile'].includes(op.operation));
 const admin=b.snapshot?.campaign_bootstrap===true || b.snapshot?.area_outside===true && b.snapshot?.map_available===false || adminLoadout;
 const inactive=b.snapshot?.ai_status==='stopped' || admin && b.snapshot?.ai_status==='idle';
 const alreadyStopped=b.boundary==='decision' && (b.snapshot?.paused===true || admin) && inactive && !b.locked && !b.pending && !b.authorized && !b.navigation && !b.snapshot?.input_request;
 if(alreadyStopped)session.suspended=true;else await session.settle();
 const nativeBefore=inspectBeforeExport?await kernel.rpc('dm_inspect',{},b.generation):null;
 const exported=await exportCandidate(session,scope,prior,residentIds,nativeBefore);
 const envelope=await partitionSessionEnvelope(session,exported.native_boundary);
 const audit=[...structuredClone(priorAudit),...session.events.slice(eventStart).filter(e=>['dm_transition','campaign_next','campaign_items','campaign_adopt','campaign_reconcile','campaign_settle','campaign_wipeout'].includes(e.kind)).map(e=>structuredClone(e))];
 const archive={format:'tome-partition-session-v1',build:scope.build,seed:session.seed,base:{version:nextVersion,manifest_sha256:exported.manifest_sha256 ?? await digest(exported.manifest),envelope},audit,events:[],final:envelope.final};
 const native=inspectBeforeExport?nativeBefore:await kernel.rpc('dm_inspect',{},b.generation);
 return {candidate:{manifest:exported.manifest,blobs:exported.blobs,archive,view:b.state(),native},results,metrics:exported.metrics};
}
