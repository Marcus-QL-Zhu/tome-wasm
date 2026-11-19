"""Bounded textual interface inventory of a frozen ToME Lua bundle.

Matches are leads with source locations, not a claim of executable coverage.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re


def audit(root):
    patterns = {
        'particle_rule_assignment': re.compile(r'\b(?:on_remove|on_update)\s*='),
        'native_dialog': re.compile(r'\b(?:talentDialog|registerDialog|talentDialogReturn)\s*\('),
        'custom_birth_finalizer': re.compile(r'\bcustom_birthend\s*='),
        'native_hash_or_mime': re.compile(r'\brequire\s*(?:\(\s*)?[\'"](?:md5|mime)[\'"]'),
    }
    hits = {key: [] for key in patterns}
    files = 0
    for path in sorted(root.rglob('*.lua')):
        data = path.read_bytes()
        files += 1
        for line_no, line in enumerate(data.decode('utf-8').splitlines(), 1):
            if line.lstrip().startswith('--'):
                continue
            for kind, pattern in patterns.items():
                if pattern.search(line):
                    hits[kind].append({'path': path.relative_to(root).as_posix(), 'line': line_no,
                                       'source_sha256': hashlib.sha256(data).hexdigest(),
                                       'text': line.strip()[:600]})
    return {'format': 'tome-source-interface-inventory-v1', 'scope': str(root.resolve()),
            'lua_files': files, 'method': 'textual source matches; not semantic or execution proof',
            'all_talents_verified': False, 'counts': {key: len(value) for key, value in hits.items()},
            'interfaces': hits}


if __name__ == '__main__':
    p = argparse.ArgumentParser()
    p.add_argument('bundle', type=Path)
    p.add_argument('output', type=Path)
    args = p.parse_args()
    result = audit(args.bundle)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding='utf-8')
    print(json.dumps({key: result[key] for key in ('lua_files', 'counts', 'all_talents_verified')}))
