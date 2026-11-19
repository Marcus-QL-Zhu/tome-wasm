"""Bounded real AIoo door scenarios through HTTP."""
import http.client
import json
import os
from pathlib import Path
import threading
import unittest
from tome_mvp.headless_bridge import HeadlessBridge, load_config
from tome_mvp.server import create_server
from tome_mvp.service import ServiceAdapter


class AutoDoorHTTP(unittest.TestCase):
    def test_door_safety_and_continuation(self):
        config = os.environ.get('TOME_E2E_WORKER_CONFIG')
        if not config or not Path(config).is_file():
            self.skipTest('candidate config not supplied')
        for seed in (11, 12, 13, 14, 15):
            with self.subTest(seed=seed):
                args, timeout, startup = load_config(config)
                args[2] = '/auto_door_replan_fixture.lua' if seed == 15 else '/auto_door_fixture.lua'
                bridge = HeadlessBridge(args, timeout, startup)
                server = None
                try:
                    bridge.start(seed=seed, fixture='exploration')
                    server = create_server(ServiceAdapter(bridge), 0)
                    thread = threading.Thread(target=server.serve_forever, daemon=True)
                    thread.start()
                    host = f'127.0.0.1:{server.server_port}'
                    def call(method, data=None):
                        conn = http.client.HTTPConnection('127.0.0.1', server.server_port, timeout=60)
                        headers = {'Origin':'http://'+host,'Content-Type':'application/json'} if data is not None else {}
                        conn.request(method, '/api/command' if data is not None else '/api/state', json.dumps(data) if data is not None else None, headers)
                        res = conn.getresponse(); body=json.loads(res.read()); code=res.status; conn.close(); return code,body
                    _, initial=call('GET')
                    code, state=call('POST',{'type':'ai_start','revision':initial['revision'],'budget':20})
                    self.assertEqual(code,200,state)
                    for _ in range(10):
                        if state['ai_status']!='running' or state['map'][4][5]!='+': break
                        before=state
                        code,state=call('POST',{'type':'ai_step','revision':state['revision'],'control_epoch':state['control_epoch']})
                        self.assertEqual(code,200,state)
                    if seed==13:
                        self.assertEqual(state['map'][4][5],'+')
                        self.assertEqual(state['ai_stop_reason'],'door_requires_input')
                    else:
                        self.assertNotEqual(state['map'][4][5],'+')
                        self.assertEqual(state['party'][0]['x'],4)
                        self.assertEqual(state['turn'],before['turn'])
                        if seed==12:
                            self.assertEqual(state['ai_stop_reason'],'threat')
                            self.assertTrue(state['enemies'])
                        else:
                            self.assertEqual(state['ai_status'],'running')
                            code,state=call('POST',{'type':'ai_step','revision':state['revision'],'control_epoch':state['control_epoch']})
                            self.assertEqual(code,200,state)
                            self.assertEqual(state['party'][0]['x'],5)
                    if seed in (12,13):
                        turn=state['turn']
                        code, rejected=call('POST',{'type':'ai_step','revision':state['revision'],'control_epoch':before['control_epoch']})
                        self.assertEqual(code,409,rejected)
                        _, observed=call('GET')
                        self.assertEqual(observed['turn'],turn)
                finally:
                    if server:
                        server.shutdown();server.server_close();thread.join(timeout=2)
                    bridge.close()
