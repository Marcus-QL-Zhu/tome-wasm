// Experimental transport preparation. This module does not grant access to
// stored blobs and is not exposed as a browser endpoint. The caller supplies
// only a committed server-side manifest and its authorized versioned reads.
const MAX_BLOB=64*1024*1024,MAX_PARTS=4096,MAX_TOTAL=128*1024*1024;
const digestPattern=/^[0-9a-f]{64}$/;
function index(manifest,scope){
 if(!manifest || manifest.format!=='tome-partitioned-native-v1' || !Array.isArray(manifest.partitions) || manifest.partitions.length>MAX_PARTS || !manifest.hot_root || !manifest.objects)throw Error('invalid partition manifest');
 for(const key of ['build','world_id','campaign_id'])if(typeof scope?.[key]!=='string' || manifest[key]!==scope[key])throw Error('partition scope mismatch');
 const entries=new Map([['hot',manifest.hot_root]]);
 for(const p of manifest.partitions){if(typeof p.partition_id!=='string' || !p.partition_id || entries.has(p.partition_id))throw Error('invalid partition identity');entries.set(p.partition_id,p);}
 for(const [id,p] of entries){
  if(!digestPattern.test(p.blob_digest) || typeof p.root_ref!=='string' || manifest.objects[p.root_ref]?.owner!==id || !Array.isArray(p.strong_refs))throw Error('invalid partition entry');
  for(const ref of p.strong_refs)if(typeof ref!=='string' || !entries.has(manifest.objects[ref]?.owner))throw Error('unresolved strong reference');
 }
 return entries;
}
// This derives IDs from the committed manifest, never from a client-supplied
// payload. Missing strong dependencies are errors, not silently weakened refs.
export function selectPartitions(manifest,scope,selection){
 const entries=index(manifest,scope);let ids=new Set(['hot']);
 if(selection?.kind==='loadout'){
  // Strong dependencies, if any, are resolved below and remain visible in
  // the returned IDs; do not claim that such a request was hot-only.
 }else if(selection?.kind==='area'){
  if(typeof selection.area_id!=='string' || !Number.isSafeInteger(selection.floor) || selection.floor<1)throw Error('invalid area selection');
  const zones=manifest.partitions.filter(p=>p.kind==='zone' && p.area_id===selection.area_id);
  const levels=manifest.partitions.filter(p=>p.kind==='level' && p.area_id===selection.area_id && p.floor===selection.floor);
  if(zones.length>1 || levels.length>1 || levels.length && !zones.length)throw Error('invalid committed area partition');
  if(zones.length)ids.add(zones[0].partition_id);
  if(levels.length)ids.add(levels[0].partition_id);
 }else throw Error('unsupported partition selection');
 const sources=selection?.sources??[];
 if(!Array.isArray(sources)||sources.length>5)throw Error('invalid native person sources');
 for(const source of sources){
  if(!source||Object.keys(source).sort().join(',')!=='area_id,floor'||typeof source.area_id!=='string'||!Number.isSafeInteger(source.floor)||source.floor<1||source.floor>20)throw Error('invalid native person source');
  const zones=manifest.partitions.filter(p=>p.kind==='zone'&&p.area_id===source.area_id);
  const levels=manifest.partitions.filter(p=>p.kind==='level'&&p.area_id===source.area_id&&p.floor===source.floor);
  if(zones.length!==1||levels.length!==1)throw Error('native person source is not committed');
  ids.add(zones[0].partition_id);ids.add(levels[0].partition_id);
 }
 const pending=[...ids];
 while(pending.length){const id=pending.pop();for(const ref of entries.get(id).strong_refs){const owner=manifest.objects[ref].owner;if(!ids.has(owner)){ids.add(owner);pending.push(owner);}}}
 return [...ids].sort();
}
function decodeBase64(text){
 if(typeof text!=='string' || text.length>Math.ceil(MAX_BLOB/3)*4 || text.length%4!==0)throw Error('invalid partition payload');
 // A repeated-group regexp can exhaust V8's stack on valid multi-MiB blobs.
 // Check the alphabet and final padding in linear time with bounded stack use.
 const end=text.length-(text.endsWith('==')?2:text.endsWith('=')?1:0);
 for(let i=0;i<end;i++){
  const c=text.charCodeAt(i);
  if(!(c>=65&&c<=90 || c>=97&&c<=122 || c>=48&&c<=57 || c===43 || c===47))throw Error('invalid partition payload');
 }
 const raw=atob(text);if(btoa(raw)!==text)throw Error('noncanonical partition payload');const bytes=new Uint8Array(raw.length);for(let i=0;i<raw.length;i++)bytes[i]=raw.charCodeAt(i);return bytes;
}
export async function verifyAuthorizedPartitions(manifest,scope,ids,blobs){
 const entries=index(manifest,scope);
 if(!Array.isArray(ids) || ids.length===0 || new Set(ids).size!==ids.length || !blobs || typeof blobs!=='object' || Array.isArray(blobs) || Object.keys(blobs).length!==ids.length)throw Error('invalid authorized partition set');
 let total=0;const output=[];
 for(const id of ids){
  if(!entries.has(id) || !Object.hasOwn(blobs,id))throw Error('missing authorized partition');
  const bytes=decodeBase64(blobs[id]);total+=bytes.length;
  if(bytes.length>MAX_BLOB || total>MAX_TOTAL)throw Error('partition payload capacity exceeded');
  const digest=Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256',bytes)),b=>b.toString(16).padStart(2,'0')).join('');
  if(digest!==entries.get(id).blob_digest)throw Error('partition digest mismatch');
  output.push({partition_id:id,payload_base64:blobs[id]});
 }
 return output;
}
// `read` is a server-owned versioned reader; it must reject stale versions and
// enforce battle ownership. Selection is supplied by trusted operation context.
export async function prepareAuthorizedPartitions(read,scope,selection){
 const first=await read([]);
 if(!first || !Number.isSafeInteger(first.version) || !first.manifest)throw Error('invalid manifest read');
 const committed=structuredClone(first.manifest);
 const ids=selectPartitions(committed,scope,selection);
 const second=await read(ids,first.version);
 if(!second || second.version!==first.version || stable(second.manifest)!==stable(committed))throw Error('partition version changed during read');
 const blobs=await verifyAuthorizedPartitions(committed,scope,ids,second.blobs);
 const byId=new Map([['hot',committed.hot_root],...committed.partitions.map(p=>[p.partition_id,p])]);
 let bytes=0,coldBytes=0;
 for(const item of blobs){const n=atob(item.payload_base64).length;bytes+=n;if(item.partition_id!=='hot')coldBytes+=n;}
 return {version:first.version,manifest:committed,blobs,read_metrics:{partition_ids:ids,bytes,cold_bytes:coldBytes,cold_partitions:ids.filter(id=>id!=='hot').map(id=>({partition_id:id,kind:byId.get(id).kind}))}};
}
function stable(value){
 if(value===null || typeof value!=='object')return JSON.stringify(value);
 if(Array.isArray(value))return '['+value.map(stable).join(',')+']';
 return '{'+Object.keys(value).sort().map(k=>JSON.stringify(k)+':'+stable(value[k])).join(',')+'}';
}
// Normalize only output from an isolated authoritative native candidate VM.
// Unloaded owners survive from the committed manifest; this does not commit.
export async function normalizePartitionExport(scope,prior,output,expectedGeneration){
 if(!scope || !['build','world_id','campaign_id'].every(k=>typeof scope[k]==='string' && scope[k].length>0))throw Error('invalid partition scope');
 if(prior)index(prior,scope);
 if(!Number.isSafeInteger(expectedGeneration) || expectedGeneration<1 || output?.generation!==expectedGeneration || output?.format!=='tome-partitioned-native-v1' || output?.boundary!=='decision' || !['decision','campaign_admin'].includes(output?.native_boundary) || output?.world_id!==scope.world_id || output?.campaign_id!==scope.campaign_id)throw Error('native export scope or boundary mismatch');
 if(!output || typeof output.objects!=='object' || !output.objects || Array.isArray(output.objects) || !Number.isSafeInteger(output.next_ref) || output.next_ref<1 || !Number.isSafeInteger(output.next_uid) || output.next_uid<1 || !Array.isArray(output.descriptors) || !Array.isArray(output.dirty_blobs) || output.descriptors.length>MAX_PARTS+1 || output.dirty_blobs.length>MAX_PARTS+1)throw Error('invalid native partition export');
 if(prior && (output.next_ref<prior.next_ref || output.next_uid<prior.next_uid))throw Error('allocator high water decreased');
 const old=prior?new Map([['hot',prior.hot_root],...prior.partitions.map(p=>[p.partition_id,p])]):new Map();
 const descriptors=new Map(),dirty=new Map();
 for(const d of output.descriptors){
  if(!d || typeof d.partition_id!=='string' || !d.partition_id || descriptors.has(d.partition_id) || !['hot','zone','level'].includes(d.kind) || (d.kind==='hot')!==(d.partition_id==='hot') || typeof d.root_ref!=='string' || !Array.isArray(d.strong_refs))throw Error('invalid native descriptor');
  if(d.kind!=='hot' && (typeof d.area_id!=='string' || !d.area_id))throw Error('invalid native area');
  if(d.kind==='level' && (!Number.isSafeInteger(d.floor) || d.floor<1))throw Error('invalid native floor');
  if(d.kind!=='level' && d.floor!==undefined || d.kind==='hot' && d.area_id!==undefined)throw Error('invalid descriptor location');
  const expected=d.kind==='hot'?['partition_id','kind','root_ref','strong_refs']:d.kind==='zone'?['partition_id','kind','area_id','root_ref','strong_refs']:['partition_id','kind','area_id','floor','root_ref','strong_refs'];
  if(Object.keys(d).some(k=>!expected.includes(k)) || expected.some(k=>!Object.hasOwn(d,k)))throw Error('unexpected descriptor fields');
  descriptors.set(d.partition_id,d);
 }
 if(!descriptors.has('hot'))throw Error('native hot descriptor missing');
 for(const b of output.dirty_blobs){
  if(!b || typeof b.partition_id!=='string' || dirty.has(b.partition_id) || !descriptors.has(b.partition_id) || !Number.isSafeInteger(b.bytes) || b.bytes<0 || typeof b.payload_base64!=='string')throw Error('invalid native dirty blob');
  const d=descriptors.get(b.partition_id);
  if(b.root_ref!==d.root_ref || stable(b.strong_refs)!==stable(d.strong_refs))throw Error('dirty blob metadata mismatch');
  dirty.set(b.partition_id,b);
 }
 if(dirty.size!==descriptors.size)throw Error('resident partition payload missing');
 const records=structuredClone(output.objects),dirtyIds=new Set(dirty.keys());
 if(prior){
  const keys=new Set([...Object.keys(prior.objects),...Object.keys(records)]);
  for(const key of keys){const before=prior.objects[key],after=records[key];
   if(before?.owner!==after?.owner){if(before && !dirtyIds.has(before.owner) || after && !dirtyIds.has(after.owner))throw Error('partition ownership change requires both owners');}
   else if(before && !dirtyIds.has(before.owner) && stable(before)!==stable(after))throw Error('unloaded object metadata changed');
  }
 }
 const entries=new Map(old),blobs={},readMetrics={dirty_partition_ids:[],exported_bytes:0,dirty_bytes:0};
 for(const [id,d] of descriptors){
  const b=dirty.get(id),bytes=decodeBase64(b.payload_base64);
  if(bytes.length!==b.bytes || bytes.length>MAX_BLOB)throw Error('native partition size mismatch');
  readMetrics.exported_bytes+=bytes.length;if(readMetrics.exported_bytes>MAX_TOTAL)throw Error('native partition payload capacity exceeded');
  const sha=Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256',bytes)),v=>v.toString(16).padStart(2,'0')).join('');
  const e=d.kind==='hot'?{root_ref:d.root_ref,blob_digest:sha,strong_refs:[...d.strong_refs].sort()}:{partition_id:id,kind:d.kind,area_id:d.area_id,...(d.kind==='level'?{floor:d.floor}:{}),root_ref:d.root_ref,blob_digest:sha,strong_refs:[...d.strong_refs].sort()};
  const previous=old.get(id);
  if(previous && previous.blob_digest===sha){
   if(stable({...previous,strong_refs:[...previous.strong_refs].sort()})!==stable(e))throw Error('unchanged partition metadata changed');
   const owned=obj=>Object.fromEntries(Object.entries(obj).filter(([,v])=>v.owner===id));
   if(stable(owned(prior.objects))!==stable(owned(records)))throw Error('unchanged partition objects changed');
  }else{if(!Object.hasOwn(blobs,sha))readMetrics.dirty_bytes+=bytes.length;blobs[sha]=b.payload_base64;readMetrics.dirty_partition_ids.push(id);}
  entries.set(id,previous && previous.blob_digest===sha?structuredClone(previous):e);
 }
 const manifest={format:'tome-partitioned-native-v1',build:scope.build,world_id:scope.world_id,campaign_id:scope.campaign_id,hot_root:entries.get('hot'),partitions:[...entries].filter(([id])=>id!=='hot').map(([,e])=>e).sort((a,b)=>a.partition_id.localeCompare(b.partition_id)),next_ref:output.next_ref,next_uid:output.next_uid,objects:records};
 index(manifest,scope);
 for(const [ref,v] of Object.entries(records))if(!v || typeof v.owner!=='string' || !entries.has(v.owner))throw Error('unknown native object owner');
 return {manifest,blobs,metrics:readMetrics};
}
// The native exporter uses these trusted references to retain bodies that are
// still required by unloaded owners. Never accept this list from a browser.
export function protectedColdReferences(manifest,scope,residentIds){
 return [...new Set(Object.values(protectedReferencesByOwner(manifest,scope,residentIds)).flat())].sort();
}
// Native code determines actual rewritten owners. Prefetch is not a write.
export function protectedReferencesByOwner(manifest,scope,residentIds){
 const entries=index(manifest,scope);
 if(!Array.isArray(residentIds) || !residentIds.includes('hot') || new Set(residentIds).size!==residentIds.length || residentIds.some(id=>!entries.has(id)))throw Error('invalid resident partition set');
 const groups=Object.create(null);
 for(const [id,entry] of entries)if(id!=='hot')groups[id]=[...new Set(entry.strong_refs)].sort();
 return groups;
}
