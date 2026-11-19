"""Private immutable v1 manifest cache and hot-only reconstruction.

Not an input format for clients. Instances are made only from a fully validated
canonical manifest and promoted only after the corresponding COMMIT and ACK.
"""
from bisect import bisect_left
from dataclasses import dataclass
import base64
import binascii
import hashlib
import json
import re
from . import native_partition_store as full


def _b(value):return full._wire(value).encode('utf8')


@dataclass(frozen=True,slots=True)
class HotBaseline:
    canonical: bytes
    cold_keys: tuple
    cold_bytes: bytes
    cold_spans: tuple
    hot_records: tuple
    protected: frozenset
    fields: tuple
    hot_descriptor: bytes
    next_ref: int
    next_uid: int


def baseline(canonical):
    if not isinstance(canonical,bytes):raise ValueError('canonical bytes required')
    manifest=json.loads(canonical)
    if full.validate_manifest(manifest).encode('utf8')!=canonical:raise ValueError('noncanonical parent manifest')
    if manifest['hot_root']['strong_refs']:raise ValueError('hot parent has cold dependencies')
    cold=[];hot=[]
    for key,value in sorted(manifest['objects'].items()):
        val=_b(value)
        if value['owner']=='hot':hot.append((key,val))
        else:cold.append((key,_b(key)+b':'+val))
    chunks=[];spans=[];offset=0
    for key,member in cold:
        if chunks:chunks.append(b',');offset+=1
        start=offset;chunks.append(member);offset+=len(member);spans.append((start,offset))
    hot_keys=frozenset(k for k,_ in hot)
    protected=frozenset(ref for p in manifest['partitions'] for ref in p['strong_refs'] if ref in hot_keys)
    fields=tuple((k,_b(v)) for k,v in sorted(manifest.items()) if k not in ('objects','hot_root','next_ref','next_uid'))
    return HotBaseline(canonical,tuple(k for k,_ in cold),b''.join(chunks),tuple(spans),tuple(hot),protected,fields,_b(manifest['hot_root']),manifest['next_ref'],manifest['next_uid'])


@dataclass(frozen=True,slots=True)
class HotPrepared:
    canonical: bytes
    digest: str
    blob_digest: str
    blob_data: bytes
    blob_base64: str
    unchanged: bool
    next_baseline: HotBaseline


def rebuild(parent,delta,descriptor,blob,next_ref,next_uid,expected_sha):
    if not isinstance(parent,HotBaseline):raise ValueError('trusted hot parent required')
    if not isinstance(delta,dict) or set(delta)!={'format','owner','records','retired'} or delta['format']!='tome-hot-index-delta-v1' or delta['owner']!='hot':raise ValueError('invalid hot delta')
    if not isinstance(descriptor,dict) or set(descriptor)!={'partition_id','kind','root_ref','strong_refs'} or descriptor['partition_id']!='hot' or descriptor['kind']!='hot' or descriptor['strong_refs']!=[]:raise ValueError('invalid hot descriptor')
    if not isinstance(blob,dict) or set(blob)!={'partition_id','root_ref','strong_refs','payload_base64','bytes'} or blob['partition_id']!='hot' or blob['root_ref']!=descriptor['root_ref'] or blob['strong_refs']!=[]:raise ValueError('invalid hot blob')
    if not full._id(next_ref) or not full._id(next_uid) or next_ref<parent.next_ref or next_uid<parent.next_uid:raise ValueError('allocator high water decreased')
    records=delta['records'];retired=delta['retired']
    if not isinstance(records,dict) or len(records)+len(parent.cold_keys)>full.MAX_REFS or not isinstance(retired,list) or len(retired)>full.MAX_REFS or any(not isinstance(x,str) for x in retired) or len(retired)!=len(set(retired)):
        raise ValueError('invalid hot records')
    old=dict(parent.hot_records);fresh=[]
    for ref,value in records.items():
        if not isinstance(ref,str) or not re.fullmatch(r'(?:e|r):[1-9][0-9]{0,15}',ref) or not isinstance(value,dict) or set(value) not in ({'owner','kind'},{'owner','kind','class'}):raise ValueError('invalid hot reference')
        kind=value['kind']
        if value['owner']!='hot' or kind not in ('entity','table','class','function','environment') or (ref.startswith('e:'))!=(kind=='entity') or ('class' in value and not full._name(value['class'])):raise ValueError('invalid hot reference type')
        number=int(ref[2:]);prior=parent.next_uid if kind=='entity' else parent.next_ref;upper=next_uid if kind=='entity' else next_ref
        if number>=upper or number<prior and ref not in old:raise ValueError('hot reference owner or high water mismatch')
        encoded=_b(value)
        if ref in old:
            previous=json.loads(old[ref]);current=json.loads(encoded)
            if previous['kind']!=current['kind'] or previous.get('class')!=current.get('class'):raise ValueError('hot reference type changed')
        fresh.append((ref,encoded))
    if not isinstance(descriptor['root_ref'],str) or descriptor['root_ref'] not in records:raise ValueError('hot root missing')
    fresh.sort();newrefs={k for k,_ in fresh}
    if set(retired)!=set(old)-newrefs or not parent.protected<=newrefs:raise ValueError('invalid retired or protected references')
    encoded_blob=blob['payload_base64']
    if not isinstance(encoded_blob,str) or len(encoded_blob)>((full.MAX_BLOB+2)//3)*4 or type(blob['bytes']) is not int or not 0<=blob['bytes']<=full.MAX_BLOB:raise ValueError('invalid hot blob capacity')
    try:data=base64.b64decode(encoded_blob,validate=True)
    except (ValueError,binascii.Error):raise ValueError('invalid hot base64') from None
    if len(data)!=blob['bytes'] or base64.b64encode(data).decode('ascii')!=encoded_blob:raise ValueError('invalid hot blob encoding')
    digest=hashlib.sha256(data).hexdigest();new_hot={'root_ref':descriptor['root_ref'],'blob_digest':digest,'strong_refs':[]};new_hot_bytes=_b(new_hot)
    previous_hot=json.loads(parent.hot_descriptor)
    unchanged=digest==previous_hot['blob_digest']
    if unchanged and (new_hot_bytes!=parent.hot_descriptor or tuple(fresh)!=parent.hot_records):raise ValueError('unchanged hot metadata changed')
    members=[];start=0
    def add_cold(end):
        nonlocal start
        if end>start:
            a=parent.cold_spans[start][0];b=parent.cold_spans[end-1][1];members.append(parent.cold_bytes[a:b]);start=end
    for ref,value in fresh:
        pos=bisect_left(parent.cold_keys,ref);add_cold(pos);members.append(_b(ref)+b':'+value)
    add_cold(len(parent.cold_keys))
    values=dict(parent.fields);values.update({'hot_root':new_hot_bytes,'next_ref':_b(next_ref),'next_uid':_b(next_uid),'objects':b'{'+b','.join(members)+b'}'})
    canonical=b'{'+b','.join(_b(k)+b':'+v for k,v in sorted(values.items()))+b'}'
    if len(canonical)>full.MAX_MANIFEST:raise ValueError('manifest capacity exceeded')
    manifest_sha=hashlib.sha256(canonical).hexdigest()
    if not isinstance(expected_sha,str) or not full.DIGEST.fullmatch(expected_sha) or manifest_sha!=expected_sha:raise ValueError('hot manifest digest mismatch')
    nxt=HotBaseline(canonical,parent.cold_keys,parent.cold_bytes,parent.cold_spans,tuple(fresh),parent.protected,parent.fields,new_hot_bytes,next_ref,next_uid)
    return HotPrepared(canonical,manifest_sha,digest,data,encoded_blob,unchanged,nxt)


def commit_hot(db,*,battle_id,expected_version,request_id,parent,prepared):
    """Private transaction commit for a locally validated immutable hot delta."""
    if not db.in_transaction or not isinstance(parent,HotBaseline) or not isinstance(prepared,HotPrepared):raise ValueError('validated hot transaction required')
    if not full._name(battle_id) or not full._name(request_id) or type(expected_version) is not int or expected_version<0:raise ValueError('invalid hot commit identity')
    row=db.execute('SELECT version,manifest FROM native_partition_versions WHERE battle_id=? ORDER BY version DESC LIMIT 1',(battle_id,)).fetchone()
    if not row or row[0]!=expected_version or row[1].encode('utf8')!=parent.canonical:raise ValueError('stale hot parent')
    blobs={} if prepared.unchanged else {prepared.blob_digest:prepared.blob_base64}
    h=hashlib.sha256();h.update(str(expected_version).encode());h.update(b'\n');h.update(prepared.canonical);h.update(b'\n');h.update(full._wire(blobs).encode('utf8'));request_hash=h.hexdigest()
    old=db.execute('SELECT request_hash,version FROM native_partition_receipts WHERE battle_id=? AND request_id=?',(battle_id,request_id)).fetchone()
    if old:
        if old[0]!=request_hash:raise ValueError('request ID conflict')
        return old[1]
    fields=dict(parent.fields);cold=json.loads(fields['partitions'])
    for entry in cold:
        if not db.execute('SELECT 1 FROM native_partition_blobs WHERE digest=?',(entry['blob_digest'],)).fetchone():raise ValueError('missing stored blob')
    existing=db.execute('SELECT data FROM native_partition_blobs WHERE digest=?',(prepared.blob_digest,)).fetchone()
    if prepared.unchanged:
        if not existing:raise ValueError('missing stored blob')
    elif existing:
        if existing[0]!=prepared.blob_data:raise ValueError('digest collision')
    else:db.execute('INSERT INTO native_partition_blobs VALUES (?,?)',(prepared.blob_digest,prepared.blob_data))
    version=expected_version+1
    db.execute('INSERT INTO native_partition_versions VALUES (?,?,?)',(battle_id,version,prepared.canonical.decode('utf8')))
    db.execute('INSERT INTO native_partition_receipts VALUES (?,?,?,?)',(battle_id,request_id,request_hash,version))
    return version
