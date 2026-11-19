// Trusted Node host only. No persistent format or browser admission is added.
import {createHash} from 'node:crypto';
import {canonical} from './battle_session.mjs';
import {protectedReferencesByOwner,selectPartitions} from './partition_transport.mjs';
const eq=(a,b)=>canonical(a)===canonical(b);
const sha=x=>createHash('sha256').update(x).digest('hex');
const name=x=>typeof x==='string' && x.length>0 && [...x].length<=256 && !/[\x00-\x1f]/.test(x);
const integer=x=>Number.isSafeInteger(x) && x>0;
const fields=(o,keys)=>o && typeof o==='object' && !Array.isArray(o) && eq(Object.keys(o).sort(),keys.sort());

export function createHotParent(manifest,scope){
 if(!manifest || !eq(selectPartitions(manifest,scope,{kind:'loadout'}),['hot']))throw Error('hot parent requires closed hot');
 const cold=[],hot={};for(const [ref,value] of Object.entries(manifest.objects)){
  if(value.owner==='hot')hot[ref]=structuredClone(value);else cold.push([ref,JSON.stringify(ref)+':'+canonical(value)]);
 }
 cold.sort((a,b)=>a[0]<b[0]?-1:a[0]>b[0]?1:0);
 const protectedByOwner=protectedReferencesByOwner(manifest,scope,['hot']);
 const protectedRefs=new Set(Object.values(protectedByOwner).flat().filter(ref=>hot[ref]));
 return {meta:structuredClone(Object.fromEntries(Object.entries(manifest).filter(([k])=>k!=='objects'))),cold,hot,protectedRefs,protectedByOwner};
}

// Reconstruct canonical v1 exactly, retaining only immutable cold member bytes.
export function hotCandidate(parent,scope,out,generation,{includeCanonical=false}={}){
 const d=out?.objects_delta,desc=out?.descriptors?.[0],blob=out?.dirty_blobs?.[0],old=parent.meta;
 if(out?.format!=='tome-partitioned-native-v1' || out.generation!==generation || out.boundary!=='decision' || out.native_boundary!=='campaign_admin' || out.world_id!==scope.world_id || out.campaign_id!==scope.campaign_id || out.objects!==undefined || !fields(d,['format','owner','records','retired']) || d.format!=='tome-hot-index-delta-v1' || d.owner!=='hot' || !d.records || typeof d.records!=='object' || Array.isArray(d.records) || !Array.isArray(d.retired) || !integer(out.next_ref) || !integer(out.next_uid) || out.next_ref<old.next_ref || out.next_uid<old.next_uid)throw Error('invalid hot native output');
 if(!Array.isArray(out.descriptors) || out.descriptors.length!==1 || !fields(desc,['partition_id','kind','root_ref','strong_refs']) || desc.partition_id!=='hot' || desc.kind!=='hot' || !Array.isArray(desc.strong_refs) || desc.strong_refs.length || !Array.isArray(out.dirty_blobs) || out.dirty_blobs.length!==1 || !fields(blob,['partition_id','root_ref','strong_refs','payload_base64','bytes']) || blob.partition_id!=='hot' || blob.root_ref!==desc.root_ref || !eq(blob.strong_refs,[]) || !Number.isSafeInteger(blob.bytes) || blob.bytes<0 || blob.bytes>64*1024*1024 || typeof blob.payload_base64!=='string')throw Error('invalid hot descriptor or blob');
 if(blob.payload_base64.length>Math.ceil((64*1024*1024)/3)*4)throw Error('hot blob capacity exceeded');
 const raw=Buffer.from(blob.payload_base64,'base64');if(raw.length!==blob.bytes || raw.toString('base64')!==blob.payload_base64)throw Error('invalid hot blob encoding');
 const hot=d.records,keys=Object.keys(hot).sort(),retired=Object.keys(parent.hot).filter(k=>!Object.hasOwn(hot,k)).sort();
 if(keys.length+parent.cold.length>1000000 || !eq(retired,d.retired))throw Error('invalid hot retired set');
 for(const ref of parent.protectedRefs)if(!Object.hasOwn(hot,ref))throw Error('protected hot reference retired');
 for(const ref of keys){const entry=hot[ref],m=/^(e|r):([1-9][0-9]{0,15})$/.exec(ref),previous=parent.hot[ref];
  if(!m || !(fields(entry,['owner','kind']) || fields(entry,['owner','kind','class'])) || entry.owner!=='hot' || !['entity','table','class','function','environment'].includes(entry.kind) || (m[1]==='e')!==(entry.kind==='entity') || ('class' in entry && !name(entry.class)) || previous && (previous.kind!==entry.kind || previous.class!==entry.class))throw Error('invalid hot record');
  const n=Number(m[2]),limit=m[1]==='e'?out.next_uid:out.next_ref,oldLimit=m[1]==='e'?old.next_uid:old.next_ref;
  if(!integer(n) || n>=limit || !previous && n<oldLimit)throw Error('hot reference outside allocator range');
 }
 if(!Object.hasOwn(hot,desc.root_ref))throw Error('hot root absent');
 const digest=sha(raw),hotRoot={root_ref:desc.root_ref,blob_digest:digest,strong_refs:[]};
 if(digest===old.hot_root.blob_digest && (!eq(old.hot_root,hotRoot) || !eq(parent.hot,hot)))throw Error('unchanged hot differs');
 const meta={...old,hot_root:hotRoot,next_ref:out.next_ref,next_uid:out.next_uid};
 const members=[];let i=0,j=0;while(i<parent.cold.length || j<keys.length){if(j>=keys.length || i<parent.cold.length && parent.cold[i][0]<keys[j])members.push(parent.cold[i++][1]);else {const ref=keys[j++];members.push(JSON.stringify(ref)+':'+canonical(hot[ref]));}}
 const top=Object.keys({...meta,objects:null}).sort();const text='{'+top.map(k=>JSON.stringify(k)+':'+(k==='objects'?'{'+members.join(',')+'}':canonical(meta[k]))).join(',')+'}';
 if(Buffer.byteLength(text)>32*1024*1024)throw Error('manifest capacity exceeded');
 return {manifest_sha256:sha(text),...(includeCanonical?{canonical:text}:{}),nextParent:{meta,cold:parent.cold,hot:structuredClone(hot),protectedRefs:parent.protectedRefs,protectedByOwner:parent.protectedByOwner},compact:{objects_delta:structuredClone(d),descriptor:structuredClone(desc),blob:structuredClone(blob),next_ref:out.next_ref,next_uid:out.next_uid}};
}
