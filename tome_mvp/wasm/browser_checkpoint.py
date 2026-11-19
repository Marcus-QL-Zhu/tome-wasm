"""Persist player-owned native snapshots. Never replay player combat here."""
import hashlib
import json
import os
import tempfile
from pathlib import Path


def wire(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(',', ':'), allow_nan=False)


def retain_submission(database, encoded):
    """Keep the original submission even if validation or SQLite commit fails."""
    raw = encoded.encode('utf8')
    folder = Path(database).parent / 'checkpoint-submissions'
    folder.mkdir(mode=0o700, exist_ok=True)
    request = json.loads(encoded)
    original = {k: v for k, v in request.items() if k != 'snapshot'}
    target = folder / (hashlib.sha256(wire(original).encode('utf8')).hexdigest() + '.json')
    if target.exists():
        if target.read_bytes() != raw:
            raise ValueError('checkpoint submission digest conflict')
        return
    fd, name = tempfile.mkstemp(dir=folder, prefix='.incoming-')
    try:
        with os.fdopen(fd, 'wb') as stream:
            stream.write(raw)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(name, target)
        if os.name != 'nt':
            directory = os.open(folder, os.O_RDONLY | os.O_DIRECTORY)
            try:
                os.fsync(directory)
            finally:
                os.close(directory)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def restore_submission(database, request):
    """An old page may retry its exact request after its snapshot was retained."""
    if 'snapshot' in request:
        return request
    digest = hashlib.sha256(wire(request).encode('utf8')).hexdigest()
    path = Path(database).parent / 'checkpoint-submissions' / (digest + '.json')
    if not path.is_file():
        return request
    if path.stat().st_size > 80 * 1024 * 1024:
        raise ValueError('retained checkpoint exceeds capacity')
    saved = json.loads(path.read_text(encoding='utf8'))
    if {k: v for k, v in saved.items() if k != 'snapshot'} != request or 'snapshot' not in saved:
        raise ValueError('retained checkpoint request mismatch')
    return saved


def accept_snapshot(db, battle_id, version, previous, incoming, snapshot):
    """Check scope, parent and state bindings; blob integrity is checked at commit."""
    from . import native_partition_store as parts
    if not isinstance(snapshot, dict) or set(snapshot) != {'manifest', 'blobs', 'archive', 'view', 'native'}:
        raise ValueError('complete browser native snapshot required')
    row = db.execute('SELECT manifest FROM native_partition_versions WHERE battle_id=? AND version=?', (battle_id, version)).fetchone()
    if not row:
        raise ValueError('snapshot parent unavailable')
    parent = json.loads(row[0])
    manifest = snapshot['manifest']
    parts.validate_manifest(manifest)
    if any(manifest[k] != parent[k] for k in ('build', 'world_id', 'campaign_id')):
        raise ValueError('snapshot scope mismatch')
    archive, view, native = (snapshot[k] for k in ('archive', 'view', 'native'))
    if not all(isinstance(x, dict) for x in (archive, view, native)):
        raise ValueError('snapshot state missing')
    base = archive.get('base', {})
    envelope = base.get('envelope', {})
    final = hashlib.sha256(wire(view).encode('utf8')).hexdigest()
    if (set(archive) != set(previous) or archive.get('format') != previous['format']
            or archive.get('build') != previous['build'] or archive.get('seed') != previous['seed']
            or archive.get('audit') != previous['audit'] or archive.get('events') != []
            or base.get('version') != version + 1
            or base.get('manifest_sha256') != hashlib.sha256(wire(manifest).encode('utf8')).hexdigest()
            or archive.get('final') != final or incoming.get('final') != final or envelope.get('final') != final
            or envelope.get('native_boundary') != 'decision'
            or any(type(envelope.get(k)) is not int or envelope[k] < (1 if k == 'generation' else 0) for k in ('generation', 'revision', 'epoch'))
            or envelope.get('generation') != view.get('generation')
            or envelope.get('revision') != view.get('revision')
            or view.get('input_request') is not None or view.get('paused') is not True
            or view.get('ai_status') not in ('stopped', 'idle')
            or type(view.get('turn')) is not int or view['turn'] < 0
            or view.get('status') not in ('active', 'victory', 'defeat')):
        raise ValueError('snapshot state binding mismatch')
    old = db.execute('SELECT view,native FROM battles WHERE id=? AND version=?', (battle_id, version)).fetchone()
    old_view, old_native = (json.loads(x) for x in old)
    identities = lambda doc: [(p.get('uid'), p.get('world_id'), p.get('origin')) for p in doc.get('party', [])]
    if (not native.get('party') or identities(native) != identities(old_native)
            or [p.get('id') for p in view.get('party', [])] != [p.get('uid') for p in native['party']]
            or view['turn'] < old_view.get('turn', 0)):
        raise ValueError('snapshot party or turn mismatch')
    return snapshot
