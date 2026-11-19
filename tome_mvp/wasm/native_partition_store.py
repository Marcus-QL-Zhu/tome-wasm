"""Transactional storage for trusted native partition candidates.

This module does not accept browser input. The caller must supply the output of
an isolated, authoritative native VM and use the same SQLite transaction as
its battle update. Old manifests and blobs remain available for rollback.
"""
import base64
import binascii
import hashlib
import json
import re

FORMAT = 'tome-partitioned-native-v1'
MAX_BLOB = 64 * 1024 * 1024
MAX_PARTITIONS = 4096
MAX_REFS = 1_000_000
MAX_MANIFEST = 32 * 1024 * 1024
MAX_PAYLOAD = 128 * 1024 * 1024
DIGEST = re.compile(r'^[0-9a-f]{64}$')


def _wire(x):
    return json.dumps(x, sort_keys=True, separators=(',', ':'), ensure_ascii=False, allow_nan=False)


def _name(x):
    return isinstance(x, str) and 0 < len(x) <= 256 and not any(ord(c) < 32 for c in x)


def _id(x):
    return type(x) is int and 0 < x <= 2**53 - 1


def initialize(db):
    """Install tables in the caller's existing SessionStore database."""
    db.execute('CREATE TABLE IF NOT EXISTS native_partition_blobs (digest TEXT PRIMARY KEY, data BLOB NOT NULL)')
    db.execute('CREATE TABLE IF NOT EXISTS native_partition_versions (battle_id TEXT NOT NULL, version INTEGER NOT NULL, manifest TEXT NOT NULL, PRIMARY KEY(battle_id, version))')
    db.execute('CREATE TABLE IF NOT EXISTS native_partition_receipts (battle_id TEXT NOT NULL, request_id TEXT NOT NULL, request_hash TEXT NOT NULL, version INTEGER NOT NULL, PRIMARY KEY(battle_id, request_id))')


def validate_manifest(manifest):
    """Validate bounded identity, ownership and reference closure metadata."""
    if not isinstance(manifest, dict) or set(manifest) != {'format', 'build', 'world_id', 'campaign_id', 'hot_root', 'partitions', 'next_ref', 'next_uid', 'objects'}:
        raise ValueError('invalid partition manifest fields')
    if manifest['format'] != FORMAT or not all(_name(manifest[k]) for k in ('build', 'world_id', 'campaign_id')):
        raise ValueError('invalid partition identity')
    if not _id(manifest['next_ref']) or not _id(manifest['next_uid']):
        raise ValueError('invalid allocator high water')
    parts = manifest['partitions']
    if not isinstance(parts, list) or len(parts) > MAX_PARTITIONS:
        raise ValueError('invalid partition count')
    hot = manifest['hot_root']
    if not isinstance(hot, dict) or set(hot) != {'root_ref', 'blob_digest', 'strong_refs'}:
        raise ValueError('invalid hot root')
    entries = [('hot', hot)]
    ids = {'hot'}
    locations = set()
    for p in parts:
        if not isinstance(p, dict) or set(p) not in ({'partition_id','kind','area_id','root_ref','blob_digest','strong_refs'}, {'partition_id','kind','area_id','floor','root_ref','blob_digest','strong_refs'}):
            raise ValueError('invalid partition fields')
        pid, kind, area = p['partition_id'], p['kind'], p['area_id']
        if not _name(pid) or pid in ids or not _name(area) or kind not in ('zone', 'level'):
            raise ValueError('invalid partition identity')
        if (kind == 'level') != ('floor' in p) or (kind == 'level' and not _id(p['floor'])):
            raise ValueError('invalid floor')
        location = (kind, area, p.get('floor'))
        if location in locations: raise ValueError('duplicate partition location')
        locations.add(location); ids.add(pid); entries.append((pid, p))
    refs = manifest['objects']
    if not isinstance(refs, dict) or len(refs) > MAX_REFS:
        raise ValueError('invalid references')
    owners = {}
    for key, value in refs.items():
        if not isinstance(value, dict) or set(value) not in ({'owner','kind'}, {'owner','kind','class'}):
            raise ValueError('invalid reference')
        typ, owner = value['kind'], value['owner']
        if not isinstance(key, str) or not re.fullmatch(r'(?:e|r):[1-9][0-9]{0,15}', key) or typ not in ('entity','table','class','function','environment') or not isinstance(owner, str) or owner not in ids:
            raise ValueError('invalid reference identity')
        if ('class' in value and not _name(value['class'])) or (key.startswith('e:')) != (typ == 'entity'):
            raise ValueError('mismatched reference')
        number = int(key.split(':')[1])
        if number >= manifest['next_uid' if typ == 'entity' else 'next_ref']:
            raise ValueError('reference exceeds high water')
        owners[key] = owner
    total_strong = 0
    for owner, entry in entries:
        if not isinstance(entry['blob_digest'], str) or not DIGEST.fullmatch(entry['blob_digest']) or not isinstance(entry['root_ref'], str) or owners.get(entry['root_ref']) != owner:
            raise ValueError('invalid partition root or digest')
        strong = entry['strong_refs']
        if not isinstance(strong, list): raise ValueError('invalid strong references')
        total_strong += len(strong)
        if total_strong > MAX_REFS or len(strong) > MAX_REFS or any(not isinstance(ref, str) for ref in strong) or len(set(strong)) != len(strong) or any(ref not in owners or owners[ref] == owner for ref in strong):
            raise ValueError('invalid strong references')
    encoded = _wire(manifest)
    if len(encoded.encode('utf8')) > MAX_MANIFEST: raise ValueError('manifest capacity exceeded')
    return encoded


def commit(db, *, battle_id, expected_version, request_id, manifest, blobs, expected_manifest_sha256=None):
    """Commit a candidate within an already-held SQLite write transaction.

    `blobs` maps SHA-256 to strict base64 bytes. Unchanged bytes must already
    belong to the current manifest. No database-wide digest lookup is exposed.
    The caller atomically updates its battle row in this same transaction.
    """
    if not db.in_transaction: raise ValueError('write transaction required')
    if not _name(battle_id) or not _name(request_id) or type(expected_version) is not int or expected_version < 0:
        raise ValueError('invalid commit identity')
    encoded = validate_manifest(manifest)
    if expected_manifest_sha256 is not None and (not isinstance(expected_manifest_sha256,str) or not DIGEST.fullmatch(expected_manifest_sha256) or hashlib.sha256(encoded.encode('utf8')).hexdigest()!=expected_manifest_sha256):
        raise ValueError('partition candidate manifest digest mismatch')
    if not isinstance(blobs, dict) or len(blobs) > MAX_PARTITIONS + 1:
        raise ValueError('invalid blob payload')
    if any(not isinstance(v, str) for v in blobs.values()) or sum(len(v) for v in blobs.values()) > MAX_PAYLOAD * 4 // 3 + 4:
        raise ValueError('blob payload capacity exceeded')
    target = {manifest['hot_root']['blob_digest']} | {p['blob_digest'] for p in manifest['partitions']}
    if set(blobs) - target: raise ValueError('unreferenced blob payload')
    request_hash = hashlib.sha256((str(expected_version)+'\n'+encoded+'\n'+_wire(blobs)).encode('utf8')).hexdigest()
    old_receipt = db.execute('SELECT request_hash,version FROM native_partition_receipts WHERE battle_id=? AND request_id=?',(battle_id, request_id)).fetchone()
    if old_receipt:
        if old_receipt[0] != request_hash: raise ValueError('request ID conflict')
        return old_receipt[1]
    row = db.execute('SELECT version,manifest FROM native_partition_versions WHERE battle_id=? ORDER BY version DESC LIMIT 1',(battle_id,)).fetchone()
    if row and row[0] != expected_version: raise ValueError('stale partition version')
    prior = json.loads(row[1]) if row else None
    if prior and any(prior[k] != manifest[k] for k in ('build','world_id','campaign_id')):
        raise ValueError('partition scope mismatch')
    if prior:
        old_entries = {'hot':prior['hot_root'], **{p['partition_id']:p for p in prior['partitions']}}
        new_entries = {'hot':manifest['hot_root'], **{p['partition_id']:p for p in manifest['partitions']}}
        old_by_owner = {}
        new_by_owner = {}
        for key, value in prior['objects'].items(): old_by_owner.setdefault(value['owner'], {})[key] = value
        for key, value in manifest['objects'].items(): new_by_owner.setdefault(value['owner'], {})[key] = value
        for owner, entry in new_entries.items():
            old = old_entries.get(owner)
            if old and old['blob_digest'] == entry['blob_digest']:
                old_objects = old_by_owner.get(owner, {})
                new_objects = new_by_owner.get(owner, {})
                if old != entry or old_objects != new_objects:
                    raise ValueError('unchanged blob metadata changed')
        if manifest['next_ref'] < prior['next_ref'] or manifest['next_uid'] < prior['next_uid']:
            raise ValueError('allocator high water decreased')
    decoded = {}
    for digest, encoded_blob in blobs.items():
        if not isinstance(digest, str) or not DIGEST.fullmatch(digest) or not isinstance(encoded_blob,str) or len(encoded_blob) > ((MAX_BLOB+2)//3)*4:
            raise ValueError('invalid blob payload')
        try: data = base64.b64decode(encoded_blob, validate=True)
        except (binascii.Error, ValueError): raise ValueError('invalid base64') from None
        if base64.b64encode(data).decode('ascii') != encoded_blob or len(data) > MAX_BLOB or hashlib.sha256(data).hexdigest() != digest:
            raise ValueError('blob digest or encoding mismatch')
        decoded[digest] = data
    for owner, entry in [('hot', manifest['hot_root'])] + [(p['partition_id'], p) for p in manifest['partitions']]:
        digest = entry['blob_digest']
        if digest not in decoded and (not prior or owner not in old_entries or old_entries[owner]['blob_digest'] != digest):
            raise ValueError('missing authorized blob')
        if digest not in decoded and not db.execute('SELECT 1 FROM native_partition_blobs WHERE digest=?',(digest,)).fetchone():
            raise ValueError('missing stored blob')
    for digest, data in decoded.items():
        existing = db.execute('SELECT data FROM native_partition_blobs WHERE digest=?',(digest,)).fetchone()
        if existing and existing[0] != data: raise ValueError('digest collision')
        if not existing: db.execute('INSERT INTO native_partition_blobs VALUES (?,?)',(digest,data))
    version = expected_version + 1
    db.execute('INSERT INTO native_partition_versions VALUES (?,?,?)',(battle_id,version,encoded))
    db.execute('INSERT INTO native_partition_receipts VALUES (?,?,?,?)',(battle_id,request_id,request_hash,version))
    return version


def _read_selected(db, manifest, partition_ids):
    """Read from a manifest already validated in this same DB transaction.

    Private: the caller owns the freshly parsed manifest and must not mutate it
    between validation and this call. Never pass client-owned mutable input.
    """
    if not db.in_transaction: raise ValueError('partition read transaction required')
    entries = {'hot': manifest['hot_root'], **{p['partition_id']:p for p in manifest['partitions']}}
    if not isinstance(partition_ids, list) or len(partition_ids) > MAX_PARTITIONS+1 or any(not isinstance(p, str) for p in partition_ids) or len(set(partition_ids)) != len(partition_ids) or any(p not in entries for p in partition_ids):
        raise ValueError('unauthorized partition request')
    result = {}
    for pid in partition_ids:
        digest = entries[pid]['blob_digest']
        blob = db.execute('SELECT data FROM native_partition_blobs WHERE digest=?',(digest,)).fetchone()
        if not blob or hashlib.sha256(blob[0]).hexdigest() != digest: raise ValueError('missing or corrupt partition')
        result[pid] = base64.b64encode(blob[0]).decode('ascii')
    return result


def read(db, *, battle_id, version, partition_ids):
    """Read only named partitions from a specific trusted manifest."""
    row = db.execute('SELECT manifest FROM native_partition_versions WHERE battle_id=? AND version=?',(battle_id,version)).fetchone()
    if not row: raise ValueError('unknown partition version')
    latest = db.execute('SELECT MAX(version) FROM native_partition_versions WHERE battle_id=?',(battle_id,)).fetchone()[0]
    if version != latest: raise ValueError('stale partition version')
    manifest = json.loads(row[0]); validate_manifest(manifest)
    # Public read may be called with SQLite implicit autocommit by existing
    # callers. Its single SELECT still reads only explicitly authorized bytes.
    if db.in_transaction:
        return manifest, _read_selected(db,manifest,partition_ids)
    db.execute('BEGIN')
    try:
        # Recheck version under the new read snapshot before reading payloads.
        row2=db.execute('SELECT version,manifest FROM native_partition_versions WHERE battle_id=? ORDER BY version DESC LIMIT 1',(battle_id,)).fetchone()
        if not row2 or row2[0]!=version or row2[1]!=row[0]:raise ValueError('stale partition version')
        return manifest, _read_selected(db,manifest,partition_ids)
    finally:
        db.rollback()
