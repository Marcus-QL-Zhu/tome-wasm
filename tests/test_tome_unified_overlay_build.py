import hashlib
import json
import subprocess
import tempfile
import unittest
from pathlib import Path
from scripts.build_tome_unified_battle_overlay import build
from tome_mvp.wasm.session_store import SessionStore


class UnifiedOverlayBuildTests(unittest.TestCase):
    def test_inline_runtime_is_syntax_valid_and_tamper_checked(self):
        names = ['host/tome_partition_host.mjs', 'host/tome_partition_migrate.mjs',
                 'host/tome_partition_candidate.mjs', 'host/tome_validate_operations.mjs',
                 'host/partition_session_host.mjs', 'host/partition_transport.mjs',
                 'public/battle_session.mjs', 'public/engine_bridge.mjs',
                 'public/kernel_runtime.mjs', 'public/encounter_overlay.mjs',
                 'public/partition_session.mjs', 'public/partition_transport.mjs']
        with tempfile.TemporaryDirectory() as tmp:
            base, out = Path(tmp)/'base', Path(tmp)/'out'
            (base/'public').mkdir(parents=True); (base/'host').mkdir()
            for name in names:
                (base/name).write_text('// fixture\n', encoding='utf8')
            (base/'public/kernel_runtime.mjs').write_text('export async function createKernel(mod,hooks){\n if(hooks.prepare)await hooks.prepare(mod);\n}\n', encoding='utf8')
            for name in ('tome.js', 'tome.wasm', 'tome.data'):
                (base/'public'/name).write_bytes(b'binary')
            inputs = {'lua': {}, 'host_scripts': {name: {} for name in names}}
            build_id = hashlib.sha256(json.dumps(inputs, sort_keys=True).encode()).hexdigest()[:16]
            (base/'public/browser_worker.mjs').write_text(build_id, encoding='utf8')
            (base/'identity.json').write_text(json.dumps({'build_id': build_id, 'inputs': inputs}), encoding='utf8')
            outputs = {name: {'bytes': 6, 'sha256': hashlib.sha256(b'binary').hexdigest()} for name in ('tome.js','tome.wasm','tome.data')}
            (base/'build.json').write_text(json.dumps({'outputs': outputs}), encoding='utf8')
            built = build(base, out)
            identity=json.loads((out/'identity.json').read_text(encoding='utf8'))
            encoder=Path('tome_mvp/headless/json_validate.lua').read_text(encoding='utf8').encode('utf8')
            self.assertEqual(identity['inputs']['lua']['bundle/headless/json_validate.lua'],
                             {'sha256':hashlib.sha256(encoder).hexdigest(),'bytes':len(encoder)})
            self.assertEqual(identity['inputs']['unified_battle']['modules']['json_validate.lua'],
                             hashlib.sha256(encoder).hexdigest())
            runtime = out/'public/kernel_runtime.mjs'
            text = runtime.read_text(encoding='utf8')
            self.assertNotIn("from './unified_battle_overlay.mjs'", text)
            self.assertNotIn("from './native_zone_overlay.mjs'", text)
            self.assertIn('function installNativeZoneFixes(', text)
            self.assertIn('function installUnifiedBattle(', text)
            self.assertIn('generation callback lacks new actor provenance', text)
            subprocess.run(['node', '--check', str(runtime)], check=True, capture_output=True)
            store = SessionStore(out/'battle.sqlite', out/'public', native_partitions=True)
            store._partition_frozen_host('tome_partition_host.mjs', built)
            runtime.write_text(text+'\n// tamper\n', encoding='utf8')
            with self.assertRaisesRegex(ValueError, 'dependency mismatch'):
                store._partition_frozen_host('tome_partition_host.mjs', built)


if __name__ == '__main__':
    unittest.main()
