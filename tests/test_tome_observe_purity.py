"""Check that read-only native observations do not change RNG or world state."""
import json
import os
from pathlib import Path
import subprocess
import unittest
from tome_graph_equal import check


class ObservePurity(unittest.TestCase):
    def test_repeated_observe_keeps_native_snapshot(self):
        path = os.environ.get('TOME_E2E_WORKER_CONFIG')
        if not path or not Path(path).is_file():
            self.skipTest('candidate config not supplied')
        args = json.loads(Path(path).read_text(encoding='utf-8'))['worker_argv']
        def req(i, method, params, generation=None):
            msg = {'id': i, 'protocol': 'tome-headless-v1', 'method': method, 'params': params}
            if generation is not None:
                msg['expected_generation'] = generation
            return msg
        messages = [req(1, 'create', {'seed': 11, 'fixture': 'skill_types'}), req(2, 'act', {'type': 'wait'}, 1),
                    req(3, 'save', {}, 1), req(4, 'observe', {}), req(5, 'observe', {}),
                    req(6, 'save', {}, 1)]
        proc = subprocess.run(args, input=''.join(json.dumps(x) + '\n' for x in messages),
                              capture_output=True, text=True, encoding='utf-8', errors='replace', timeout=120)
        self.assertEqual(proc.returncode, 0, proc.stderr[-3000:])
        responses = [json.loads(x) for x in proc.stdout.splitlines()]
        self.assertEqual(len(responses), 6)
        for item in responses:
            self.assertTrue(item['ok'], item)
        self.assertEqual(responses[3]['result'], responses[4]['result'])
        before, after = (responses[i]['result']['archive']['snapshot'] for i in (2, 5))
        self.assertEqual(before['rng'], after['rng'])
        check(before['graph'], after['graph'])
        self.assertEqual(before['next_uid'], after['next_uid'])
