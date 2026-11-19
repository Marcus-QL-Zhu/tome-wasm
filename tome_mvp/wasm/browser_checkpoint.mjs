import {normalizePartitionExport,protectedReferencesByOwner,selectPartitions} from './partition_transport.mjs';
import {digest} from './battle_session.mjs';

export function collectDownFacts(facts,view){
 const seen=new Set(facts.down_events.map(e=>e.actor_id+':'+e.serial));
 for(const event of view.down_events || []){
  const key=event.actor_id+':'+event.serial;
  if(!seen.has(key)){facts.down_events.push({actor_id:event.actor_id,serial:event.serial,turn:event.turn,generation:view.generation});seen.add(key);}
 }
 return facts;
}

// The browser owns combat. Export once at a stopped save boundary, then retain
// these exact bytes for retries. The server persists them without replaying turns.
export async function exportBrowserCheckpoint(session,parent,version){
 const b=session?.bridge;
 if(!session?.suspended || !session.partitionOnly || b.locked || b.pending || b.authorized || b.navigation || !['decision','terminal'].includes(b.boundary) || b.snapshot?.input_request)throw Error('snapshot requires a stopped decision boundary');
 const scope={build:parent.build,world_id:parent.world_id,campaign_id:parent.campaign_id};
 const ids=selectPartitions(parent,scope,{kind:'loadout'});
 const native=await b.rpc('dm_inspect',{},b.generation);
 if(session.combatFacts)native.combat_facts=structuredClone(session.combatFacts);
 const out=await b.rpc('partition_export',{protected_by_owner:protectedReferencesByOwner(parent,scope,ids)},b.generation);
 const exported=await normalizePartitionExport(scope,parent,out,b.generation);
 const view=structuredClone(b.state()),final=await digest(view);
 const envelope={generation:b.generation,revision:b.revision,epoch:b.epoch,reason:b.reason,final,native_boundary:out.native_boundary};
 return {manifest:exported.manifest,blobs:exported.blobs,archive:{format:'tome-partition-session-v1',build:session.build,seed:session.seed,base:{version:version+1,manifest_sha256:await digest(exported.manifest),envelope},audit:structuredClone(session.audit),events:[],final},view,native};
}
