"""Check selected build inputs before attempting a ToME build."""
import argparse
import hashlib
import json
import shutil
import sys
from tome_build_paths import SOURCE, RUNTIME, ADDON, SDK, TCC

def check_pin(path, expected):
    if not isinstance(expected, str) or len(expected) != 64 or any(c not in '0123456789abcdef' for c in expected):
        raise ValueError('invalid pin for '+str(path))
    if hashlib.sha256(path.read_bytes()).hexdigest() != expected:
        raise ValueError('hash mismatch: '+str(path))

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--pins', required=True, type=__import__('pathlib').Path, help='independently obtained runtime and SDK SHA-256 pins JSON')
    args=parser.parse_args()
    errors=[]
    manifest=SOURCE / 'source-manifest.json'
    try:
        data=json.loads(manifest.read_text(encoding='utf-8'))
        pin=data.get('archive_sha256')
        if not isinstance(pin,str) or len(pin)!=64 or any(c not in '0123456789abcdef' for c in pin): raise ValueError('no valid full archive pin')
        if not data.get('files'): raise ValueError('empty source manifest')
        for item in data['files']:
            p=(SOURCE / item['path']).resolve()
            if not p.is_relative_to(SOURCE.resolve()): raise ValueError('source path escapes root')
            if not p.is_file() or hashlib.sha256(p.read_bytes()).hexdigest() != item['sha256']: raise ValueError('source mismatch: '+str(p))
        if not {'src/core_lua.c','src/SFMT.c','src/fov.c'}.issubset({item['path'] for item in data['files']}): raise ValueError('missing required source files')
        print('source manifest verified:', len(data['files']), 'files; pin provenance must be checked independently')
    except (OSError, ValueError, KeyError, TypeError) as e: errors.append('source: '+str(e))
    addon=ADDON / 'superload/mod/class/Player.lua'
    try:
        if hashlib.sha256(addon.read_bytes()).hexdigest() != '97c501f50a730b08e18f680e548191559ece9d65f1aa246668b27ba66fb8aa97': raise ValueError('hash mismatch')
    except (OSError, ValueError) as e: errors.append('addon: '+str(e))
    try:
        pins=json.loads(args.pins.read_text(encoding='utf-8-sig'))
        paths={
            'runtime_tactical_ai':RUNTIME/'tome/mod/ai/improved_tactical.lua',
            'runtime_class':RUNTIME/'engine/engine/class.lua',
            'sdk_emcc':SDK/'upstream/emscripten/emcc.py',
        }
        # The project itself fixes identities for the first two native rule files.
        fixed={'runtime_tactical_ai':'db5766f6d3b4da93ce8d275dae2dcbd5655d0626fb4329242c9abe754c9c9829',
               'runtime_class':'e65f81d273090e02c29855d1d5b0b0452878399f7d6a8bd024ef3ec6fc498928'}
        for name,path in paths.items():
            expected=fixed.get(name, pins.get(name))
            check_pin(path,expected)
    except (OSError, ValueError, TypeError, AttributeError) as e: errors.append('runtime/toolchain: '+str(e))
    if not shutil.which('node'): errors.append('node not found on PATH')
    print('Windows compiler:', TCC, '(optional for Wasm)')
    if errors:
        print('\n'.join(errors), file=sys.stderr); return 1
    print('Inputs present; build scripts apply additional pinned source checks.'); return 0
if __name__ == '__main__': raise SystemExit(main())
