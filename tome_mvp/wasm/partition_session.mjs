import {verifyAuthorizedPartitions} from './partition_transport.mjs';
import {BattleSession,digest} from './battle_session.mjs';

// Import only already-authorized blocks into a fresh disposable VM. The saved
// bridge envelope belongs to the server version, never to a client proposal.
export async function restorePartitionCandidate(rpc,build,seed,scope,envelope,manifest,ids,blobs,warmIdentity){
 if(build!==scope?.build || !Number.isInteger(seed) || seed<0 || seed>2147483647 || !envelope || !Number.isSafeInteger(envelope.generation) || envelope.generation<1 || !Number.isSafeInteger(envelope.revision) || envelope.revision<0 || !Number.isSafeInteger(envelope.epoch) || envelope.epoch<0 || !(envelope.reason===null || typeof envelope.reason==='string') || typeof envelope.final!=='string' || !['decision','campaign_admin'].includes(envelope.native_boundary))throw Error('invalid partition session envelope');
 const verified=await verifyAuthorizedPartitions(manifest,scope,ids,blobs);
 const session=new BattleSession(rpc,build,seed),bridge=session.bridge;
 bridge.caps=await rpc('capabilities',{});if(bridge.caps?.protocol!=='tome-headless-v1')throw Error('incompatible protocol');
 const imported=await rpc('partition_import',{manifest,blobs:verified,...(warmIdentity?{warm_identity:warmIdentity}:{})});
 if(imported?.format!=='tome-partitioned-native-v1' || imported.generation!==envelope.generation || !['decision','terminal'].includes(imported.boundary) || imported.native_boundary!==envelope.native_boundary)throw Error('partition import mismatch');
 bridge.generation=imported.generation;bridge.boundary=imported.boundary;bridge.revision=envelope.revision;bridge.epoch=envelope.epoch;bridge.reason=envelope.reason;
 await bridge.observe();if(await digest(bridge.state())!==envelope.final)throw Error('partition session state mismatch');
 for(const rule of bridge.snapshot?.rule_events || [])session.rulePhases.set(bridge.generation+':'+rule.id,rule.phase);
 session.partitionOnly=true;session.nativeBoundary=imported.native_boundary;session.suspended=true;return session;
}
export async function partitionSessionEnvelope(session,nativeBoundary){
 const b=session?.bridge;
 if(!session?.suspended || !b || b.locked || b.pending || b.authorized || b.navigation || !['decision','terminal'].includes(b.boundary) || !['decision','campaign_admin'].includes(nativeBoundary))throw Error('partition envelope requires stopped boundary');
 return {generation:b.generation,revision:b.revision,epoch:b.epoch,reason:b.reason,final:await digest(b.state()),native_boundary:nativeBoundary};
}
