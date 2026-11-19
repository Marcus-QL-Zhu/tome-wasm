"""Extract selected upstream source from an explicitly SHA-256 pinned offline archive."""
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import tarfile
from tome_build_paths import SOURCE

ROOT = 't-engine4-src-1.7.6'

def sha(path):
    h = hashlib.sha256()
    with path.open('rb') as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b''): h.update(chunk)
    return h.hexdigest()

def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--archive', type=Path, required=True)
    p.add_argument('--sha256', required=True, help='trusted complete archive SHA-256')
    p.add_argument('--output', type=Path, default=SOURCE)
    a = p.parse_args()
    if len(a.sha256) != 64 or any(c not in '0123456789abcdef' for c in a.sha256): p.error('sha256 must be 64 lowercase hexadecimal characters')
    if sha(a.archive) != a.sha256: raise SystemExit('Archive SHA-256 mismatch')
    if a.output.exists() and any(a.output.iterdir()): raise SystemExit('Destination is not empty')
    a.output.mkdir(parents=True, exist_ok=True)
    files = []
    with tarfile.open(a.archive, 'r:bz2') as archive:
        for member in archive:
            parts = PurePosixPath(member.name).parts
            if not parts or parts[0] != ROOT or any(x in ('.', '..') for x in parts): raise ValueError('Unexpected archive path: ' + member.name)
            selected = len(parts) >= 2 and (parts[1] in ('src', 'build') or parts[1:] == ('premake4.lua',))
            if not selected or member.isdir(): continue
            if not member.isfile(): raise ValueError('Non-regular selected member: ' + member.name)
            target = a.output.joinpath(*parts[1:]); target.parent.mkdir(parents=True, exist_ok=True)
            with archive.extractfile(member) as source, target.open('xb') as out:
                for chunk in iter(lambda: source.read(1024 * 1024), b''): out.write(chunk)
            files.append({'path': '/'.join(parts[1:]), 'bytes': target.stat().st_size, 'sha256': sha(target)})
    if not files: raise SystemExit('No selected files')
    (a.output / 'source-manifest.json').write_text(json.dumps({'archive_sha256': a.sha256, 'archive_identity': 'caller-supplied pin; verify provenance separately', 'files': files}, indent=2) + '\n', encoding='utf-8')
    print('Extracted', len(files), 'verified-archive files')
if __name__ == '__main__': main()
