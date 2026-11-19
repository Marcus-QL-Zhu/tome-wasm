from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from tome_mvp.headless_bridge import HeadlessBridge, WorkerError, load_config

WORKER = r'''
import json, sys, time
generation = 0
for line in sys.stdin:
    req = json.loads(line); method = req['method']; params = req['params']
    if params.get('hang'): time.sleep(10)
    if method == 'capabilities': result = {'protocol': 'tome-headless-v1', 'ai_provider': 'player_aioo_custom', 'methods': {'advance': True, 'observe': True}, 'web_commands': {'wait': True, 'pause': True, 'new_game': True, 'ai_step': True}}
    elif method == 'create': generation = 1; result = {'accepted': True, 'generation': generation, 'boundary': 'decision'}
    elif req.get('expected_generation', generation) != generation:
        print(json.dumps({'id': req['id'], 'ok': False, 'error': {'code': 'stale_generation', 'outcome': 'rejected'}}), flush=True); continue
    elif method == 'reset': generation += 1; result = {'accepted': True, 'generation': generation, 'boundary': 'decision'}
    elif method == 'observe': result = {'generation': generation, 'turn': 0, 'map': {'rows': []}, 'party': [], 'enemies': [], 'capabilities': {'wait': True, 'pause': True, 'new_game': True, 'move': True, 'ai_step': True}}
    else: result = {'accepted': True, 'generation': generation, 'boundary': 'decision'}
    print(json.dumps({'id': req['id'], 'ok': True, 'result': result}), flush=True)
'''


class HeadlessBridgeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.worker = Path(self.temp.name) / 'worker.py'
        self.worker.write_text(WORKER, encoding='utf-8')
        self.bridge = HeadlessBridge([sys.executable, '-u', str(self.worker)], timeout=1, startup_timeout=3)
        self.bridge.start()

    def tearDown(self):
        self.bridge.close()
        self.temp.cleanup()

    def test_persistent_reset_and_capability_intersection(self):
        pid = self.bridge.process.pid
        state = self.bridge.observe()
        self.assertFalse(state['capabilities']['move'])
        self.assertEqual(self.bridge.command({'type': 'pause'})['turn'], 0)
        self.bridge.command({'type': 'wait'})
        self.assertEqual(self.bridge.command({'type': 'new_game', 'seed': 8})['generation'], 2)
        self.assertEqual(self.bridge.process.pid, pid)
        with self.assertRaises(ValueError): self.bridge.command({'type': 'move', 'dx': 1, 'dy': 0})
        with self.assertRaises(ValueError): self.bridge.request('act', {}, expected_generation=1)
        self.assertEqual(self.bridge.observe()['generation'], 2)

    def test_timeout_terminates_without_retry(self):
        with self.assertRaises(TimeoutError): self.bridge.request('act', {'hang': True}, expected_generation=1, timeout=0.1)
        self.assertIsNotNone(self.bridge.process.poll())
        with self.assertRaises(WorkerError): self.bridge.observe()

    def test_plain_native_ai_is_not_advertised_as_aioo(self):
        script = WORKER.replace("'ai_provider': 'player_aioo_custom', ", "")
        self.worker.write_text(script, encoding='utf-8')
        bridge = HeadlessBridge([sys.executable, '-u', str(self.worker)], startup_timeout=3)
        bridge.start()
        try:
            self.assertFalse(bridge.observe()['capabilities']['ai_step'])
            with self.assertRaises(ValueError):
                bridge.command({'type': 'ai_step'})
        finally:
            bridge.close()

    def test_ai_uses_native_action_not_advance(self):
        from unittest.mock import patch
        with patch.object(self.bridge, 'request', wraps=self.bridge.request) as request:
            state = self.bridge.command({'type': 'ai_step'})
        calls = [call for call in request.call_args_list if call.args[0] in ('act', 'advance')]
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0].args[:2], ('act', {'type': 'native_ai', 'ai_epoch': None}))
        self.assertEqual(state['advance_status'], 'decision')

    def test_ai_stop_is_used_for_pause_and_manual_when_declared(self):
        from unittest.mock import patch
        self.bridge.worker_capabilities['methods']['ai_stop'] = True
        with patch.object(self.bridge, 'request', wraps=self.bridge.request) as request:
            self.bridge.command({'type': 'pause'})
            self.bridge.command({'type': 'wait'})
        calls=[call.args[1] for call in request.call_args_list if call.args[0]=='act']
        self.assertEqual(calls, [{'type':'ai_stop','reason':'user'}, {'type':'ai_stop'}, {'type':'wait'}])

    def test_pause_uses_observe_only(self):
        from unittest.mock import patch
        with patch.object(self.bridge, 'request', wraps=self.bridge.request) as request:
            state = self.bridge.command({'type': 'pause'})
        self.assertTrue(state['capabilities']['pause'])
        self.assertEqual(state['turn'], 0)
        self.assertTrue(request.call_args_list)
        self.assertTrue(all(call.args[0] == 'observe' for call in request.call_args_list))

    def test_ai_pending_drains_after_native_action(self):
        from unittest.mock import patch
        script = WORKER.replace("else: result = {'accepted': True, 'generation': generation, 'boundary': 'decision'}", "else: result = {'accepted': True, 'generation': generation, 'boundary': 'pending' if method == 'act' else 'decision'}")
        self.worker.write_text(script, encoding='utf-8')
        bridge = HeadlessBridge([sys.executable, '-u', str(self.worker)], startup_timeout=3)
        bridge.start()
        with patch.object(bridge, 'request', wraps=bridge.request) as request:
            state = bridge.command({'type': 'ai_step'})
        calls = [call.args for call in request.call_args_list if call.args[0] in ('act', 'advance')]
        self.assertEqual(calls[0][:2], ('act', {'type': 'native_ai', 'ai_epoch': None}))
        self.assertEqual(calls[1][:2], ('advance', {'budget': 100}))
        self.assertEqual(len(calls), 2)
        self.assertEqual(state['advance_status'], 'decision')
        bridge.close()

    def test_bad_response_terminates(self):
        self.bridge.close()
        self.worker.write_text('import sys\nfor line in sys.stdin: print("{}", flush=True)\n', encoding='utf-8')
        bridge = HeadlessBridge([sys.executable, '-u', str(self.worker)], startup_timeout=2)
        with self.assertRaises(WorkerError): bridge.start()
        self.assertIsNotNone(bridge.process.poll())

    def test_duplicate_keys_and_non_boolean_ok_rejected(self):
        for response in ('{"id":1,"id":1,"ok":true,"result":{}}',
                         '{"id":1,"ok":1,"result":{}}'):
            with self.subTest(response=response):
                self.worker.write_text('import sys\nfor line in sys.stdin: print(' + repr(response) + ', flush=True)\n', encoding='utf-8')
                bridge = HeadlessBridge([sys.executable, '-u', str(self.worker)], startup_timeout=2)
                with self.assertRaises(WorkerError): bridge.start()
                self.assertIsNotNone(bridge.process.poll())

    def test_bad_handshake_and_receipts_close_worker(self):
        cases = [
            WORKER.replace("'protocol': 'tome-headless-v1', ", ""),
            WORKER.replace("'protocol': 'tome-headless-v1'", "'protocol': 'other'"),
        ]
        for script in cases:
            with self.subTest(script=script[:100]):
                self.worker.write_text(script, encoding='utf-8')
                bridge = HeadlessBridge([sys.executable, '-u', str(self.worker)], startup_timeout=3)
                with self.assertRaises(WorkerError): bridge.start()
                self.assertIsNotNone(bridge.process.poll())
                self.assertTrue(bridge.process.stdin.closed)
        for receipt in ("{'accepted': False, 'generation': generation, 'boundary': 'decision'}",
                        "{'accepted': True, 'generation': generation + 1, 'boundary': 'decision'}",
                        "{'accepted': True, 'generation': generation}"):
            with self.subTest(receipt=receipt):
                script = WORKER.replace("else: result = {'accepted': True, 'generation': generation, 'boundary': 'decision'}", "else: result = " + receipt)
                self.worker.write_text(script, encoding='utf-8')
                bridge = HeadlessBridge([sys.executable, '-u', str(self.worker)], startup_timeout=3)
                bridge.start()
                with self.assertRaises(WorkerError): bridge.command({'type': 'wait'})
                self.assertIsNotNone(bridge.process.poll())
                bridge.close()

    def test_ambiguous_error_is_unknown_and_terminates(self):
        script = WORKER.replace("'outcome': 'rejected'", "'outcome': 'unknown'")
        self.worker.write_text(script, encoding='utf-8')
        bridge = HeadlessBridge([sys.executable, '-u', str(self.worker)], startup_timeout=3)
        bridge.start()
        with self.assertRaises(WorkerError): bridge.request('act', {}, expected_generation=0)
        self.assertIsNotNone(bridge.process.poll())
        bridge.close()

    def test_pending_drain_is_bounded_and_continue_never_repeats_action(self):
        from unittest.mock import patch
        log = Path(self.temp.name) / 'requests.log'
        script = WORKER.replace("generation = 0", "generation = 0; advances = 0")
        script = script.replace("req = json.loads(line); method = req['method']; params = req['params']", "req = json.loads(line); method = req['method']; params = req['params']; open(" + repr(str(log)) + ", 'a').write(method + '\\n')")
        script = script.replace("else: result = {'accepted': True, 'generation': generation, 'boundary': 'decision'}", "else:\n        if method == 'advance': advances += 1\n        result = {'accepted': True, 'generation': generation, 'boundary': 'pending' if method == 'act' or advances < 3 else 'decision'}")
        self.worker.write_text(script, encoding='utf-8')
        bridge = HeadlessBridge([sys.executable, '-u', str(self.worker)], startup_timeout=3)
        bridge.start()
        with patch('tome_mvp.headless_bridge.MAX_DRAIN_TICKS', 2), patch('tome_mvp.headless_bridge.DRAIN_BATCH_TICKS', 1):
            state = bridge.command({'type': 'wait'})
            self.assertEqual(state['advance_status'], 'pending')
            self.assertFalse(state['capabilities']['wait'])
            self.assertFalse(state['capabilities']['ai_step'])
            self.assertTrue(state['capabilities']['continue_pending'])
            with self.assertRaises(ValueError): bridge.command({'type': 'wait'})
            state = bridge.command({'type': 'continue_pending'})
            self.assertEqual(state['advance_status'], 'decision')
            self.assertTrue(state['capabilities']['wait'])
        bridge.close()
        calls = log.read_text().splitlines()
        self.assertEqual(calls.count('act'), 1)
        self.assertEqual(calls.count('advance'), 3)

    def test_close_pipes_and_bounded_stderr(self):
        self.bridge.close()
        self.bridge.close()
        for stream in (self.bridge.process.stdin, self.bridge.process.stdout, self.bridge.process.stderr):
            self.assertTrue(stream.closed)
        script = "import sys\nsys.stderr.write('x'*50000); sys.stderr.flush()\n" + WORKER
        self.worker.write_text(script, encoding='utf-8')
        bridge = HeadlessBridge([sys.executable, '-u', str(self.worker)], startup_timeout=3)
        bridge.start()
        threads = list(bridge.threads)
        bridge.close()
        self.assertLessEqual(len(bridge.stderr_tail), 16384)
        self.assertGreater(len(bridge.stderr_tail), 0)
        self.assertFalse(any(t.is_alive() for t in threads))

    def test_drain_deadline_failure_terminates_without_replaying_act(self):
        log = Path(self.temp.name) / 'deadline.log'
        script = WORKER.replace("req = json.loads(line); method = req['method']; params = req['params']", "req = json.loads(line); method = req['method']; params = req['params']; open(" + repr(str(log)) + ", 'a').write(method + '\\n'); time.sleep(2 if method == 'advance' else 0)")
        script = script.replace("else: result = {'accepted': True, 'generation': generation, 'boundary': 'decision'}", "else: result = {'accepted': True, 'generation': generation, 'boundary': 'pending'}")
        self.worker.write_text(script, encoding='utf-8')
        bridge = HeadlessBridge([sys.executable, '-u', str(self.worker)], timeout=0.3, startup_timeout=3)
        bridge.start()
        with self.assertRaises(TimeoutError): bridge.command({'type': 'wait'})
        self.assertIsNotNone(bridge.process.poll())
        calls = log.read_text().splitlines()
        self.assertEqual(calls.count('act'), 1)
        self.assertEqual(calls.count('advance'), 1)
        bridge.close()

    def test_config_requires_argv_array(self):
        path = Path(self.temp.name) / 'runtime.json'
        path.write_text(json.dumps({'worker_argv': 'worker'}), encoding='utf-8')
        with self.assertRaises(ValueError): load_config(path)
        path.write_text(json.dumps({'worker_argv': ['worker', '--flag']}), encoding='utf-8')
        self.assertEqual(load_config(path)[0], ['worker', '--flag'])

    @unittest.skipUnless(os.name == 'nt', 'Windows process creation flag')
    def test_windows_launch_requests_no_console(self):
        from unittest.mock import patch
        bridge = HeadlessBridge(['worker'])
        with patch('tome_mvp.headless_bridge.popen_owned', side_effect=OSError('probe')) as launch:
            with self.assertRaises(OSError): bridge.start()
        self.assertTrue(launch.call_args.kwargs['creationflags'] & subprocess.CREATE_NO_WINDOW)


if __name__ == '__main__': unittest.main()
