"""Real worker navigation authorization through HTTP, when configured."""
import http.client
import json
import os
from pathlib import Path
import threading
import unittest
from tome_mvp.headless_bridge import HeadlessBridge, load_config
from tome_mvp.server import create_server
from tome_mvp.service import ServiceAdapter


class NavigationHTTP(unittest.TestCase):
    def test_step_and_revoked_epoch(self):
        config = os.environ.get('TOME_E2E_WORKER_CONFIG')
        if not config or not Path(config).is_file():
            self.skipTest('candidate config not supplied')
        bridge = HeadlessBridge(*load_config(config))
        server = None
        try:
            bridge.start(seed=11, fixture='exploration')
            server = create_server(ServiceAdapter(bridge), 0)
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            host = f'127.0.0.1:{server.server_port}'
            def call(method, data=None):
                conn = http.client.HTTPConnection('127.0.0.1', server.server_port, timeout=60)
                headers = {'Origin': 'http://' + host, 'Content-Type': 'application/json'} if data is not None else {}
                conn.request(method, '/api/command' if data is not None else '/api/state', json.dumps(data) if data is not None else None, headers)
                response = conn.getresponse(); body = json.loads(response.read()); code = response.status; conn.close()
                return code, body
            _, initial = call('GET')
            player = next(p for p in initial['party'] if p['id'] == initial['control_actor_id'])
            x,y = player['x']-1,player['y']-1
            code, started = call('POST', {'type':'navigate_start','x':x,'y':y,'revision':initial['revision']})
            self.assertEqual(code,200,started)
            self.assertEqual(started['navigation']['status'],'running')
            code, paused = call('POST', {'type':'pause','revision':started['revision']})
            self.assertEqual(code,200,paused)
            self.assertEqual(paused['navigation']['status'],'stopped')
            code, stale = call('POST', {'type':'navigate_step','revision':paused['revision'],'control_epoch':started['control_epoch']})
            self.assertEqual(code,409,stale)
            _, unchanged = call('GET')
            self.assertEqual(unchanged['turn'],initial['turn'])
            code, started = call('POST', {'type':'navigate_start','x':x,'y':y,'revision':unchanged['revision']})
            self.assertEqual(code,200,started)
            code, moved = call('POST', {'type':'navigate_step','revision':started['revision'],'control_epoch':started['control_epoch']})
            self.assertEqual(code,200,moved)
            self.assertEqual(moved['navigation']['stop_reason'],'arrived')
            player = next(p for p in moved['party'] if p['id'] == moved['control_actor_id'])
            self.assertEqual((player['x'],player['y']),(x,y))
        finally:
            if server:
                server.shutdown(); server.server_close(); thread.join(timeout=2)
            bridge.close()

    def test_visible_enemies_allow_one_retreat_then_stop(self):
        config = os.environ.get('TOME_E2E_WORKER_CONFIG')
        if not config or not Path(config).is_file():
            self.skipTest('candidate config not supplied')
        for target, reason in (((3,3),'arrived'),((2,2),'threat')):
            with self.subTest(target=target):
                bridge=HeadlessBridge(*load_config(config))
                try:
                    before=bridge.start(seed=11)
                    self.assertTrue(before['enemies'])
                    bridge.command({'type':'navigate_start','x':target[0],'y':target[1]})
                    after=bridge.command({'type':'navigate_step'})
                    self.assertEqual((after['party'][0]['x'],after['party'][0]['y']),(3,3))
                    self.assertEqual(after['navigation']['stop_reason'],reason)
                finally:
                    bridge.close()
