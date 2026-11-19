import {normalizePartitionExport,protectedReferencesByOwner,selectPartitions} from './partition_transport.mjs';

// Reconstruct the public v1 index only from the committed parent and the
// complete native hot owner index. Never accept modifications to cold owners.
export function reconstructHotIndex(prior,scope,out){
 const delta=out?.objects_delta;
 if(!prior || !delta || out.objects!==undefined || delta.format!=='tome-hot-index-delta-v1' || delta.owner!=='hot' || Object.keys(delta).sort().join(',')!=='format,owner,records,retired' || !delta.records || typeof delta.records!=='object' || Array.isArray(delta.records) || !Array.isArray(delta.retired))throw Error('invalid hot index delta');
 if(!Number.isSafeInteger(prior.next_ref) || !Number.isSafeInteger(prior.next_uid) || !Number.isSafeInteger(out.next_ref) || !Number.isSafeInteger(out.next_uid) || out.next_ref<prior.next_ref || out.next_uid<prior.next_uid)throw Error('invalid allocator high water');
 const records=delta.records,old=prior.objects,oldHot=Object.keys(old).filter(k=>old[k]?.owner==='hot');
 const retired=oldHot.filter(k=>!Object.hasOwn(records,k)).sort();
 if(JSON.stringify(retired)!==JSON.stringify(delta.retired))throw Error('invalid retired hot references');
 const protectedRefs=new Set(Object.values(protectedReferencesByOwner(prior,scope,['hot'])).flat().filter(ref=>old[ref]?.owner==='hot'));
 for(const ref of protectedRefs)if(!Object.hasOwn(records,ref))throw Error('protected hot reference retired');
 const combined=Object.fromEntries(Object.entries(old).filter(([,v])=>v.owner!=='hot'));
 for(const [ref,entry] of Object.entries(records)){
  const match=/^(e|r):([1-9][0-9]{0,15})$/.exec(ref),keys=entry && typeof entry==='object' && !Array.isArray(entry)?Object.keys(entry).sort().join(','):'';
  if(!match || !['kind,owner','class,kind,owner'].includes(keys) || entry.owner!=='hot' || !['entity','table','class','function','environment'].includes(entry.kind) || (match[1]==='e')!==(entry.kind==='entity') || ('class' in entry && (typeof entry.class!=='string' || !entry.class)) || old[ref] && old[ref].owner!=='hot')throw Error('invalid hot record');
  const n=Number(match[2]),limit=match[1]==='e'?out.next_uid:out.next_ref,oldLimit=match[1]==='e'?prior.next_uid:prior.next_ref;
  if(!Number.isSafeInteger(n) || n>=limit || !old[ref] && n<oldLimit)throw Error('invalid hot reference high water');
  combined[ref]=entry;
 }
 const expanded={...out,objects:combined};delete expanded.objects_delta;
 if(!Array.isArray(expanded.descriptors) || expanded.descriptors.length!==1 || !Array.isArray(expanded.dirty_blobs) || expanded.dirty_blobs.length!==1 || expanded.dirty_blobs[0]?.partition_id!=='hot')throw Error('delta must rewrite only hot');
 const hot=expanded.descriptors[0]?.partition_id==='hot'?expanded.descriptors[0]:null;
 if(!hot || !Array.isArray(hot.strong_refs) || hot.strong_refs.length)throw Error('hot acquired cold dependency');
 // Also validate the parent selection; only its exact hot closure is admitted.
 if(JSON.stringify(selectPartitions(prior,scope,{kind:'loadout'}))!=='["hot"]')throw Error('parent has cold dependency');
 return expanded;
}

// Experimental host-only helper. The caller must discard the candidate VM on
// any failure, including a later failed SQLite commit. Never invoke on the
// currently committed live VM: export may evict inactive native levels.
export async function exportPartitionCandidate(session,scope,prior,residentIds){
 const b=session?.bridge;
 if(!session?.suspended || !b || b.locked || b.pending || b.authorized || b.navigation || !['decision','terminal'].includes(b.boundary) || b.snapshot?.input_request)throw Error('partition export requires stopped decision boundary');
 const protected_by_owner=prior?protectedReferencesByOwner(prior,scope,residentIds):{};
 const out=await b.rpc('partition_export',{protected_by_owner},b.generation);
 const candidate=await normalizePartitionExport(scope,prior,out,b.generation);
 return {...candidate,native_boundary:out.native_boundary};
}

export {restorePartitionCandidate,partitionSessionEnvelope} from './partition_session.mjs';
