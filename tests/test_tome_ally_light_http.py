"""Ordinary shared optical sight via a real isolated worker and HTTP."""
import http.client
import json
import os
from pathlib import Path
import threading
import unittest
from tome_mvp.headless_bridge import HeadlessBridge, load_config
from tome_mvp.server import create_server
from tome_mvp.service import ServiceAdapter

class AllyLightHTTP(unittest.TestCase):
 def test_shared_light_boundaries(self):
  config=os.environ.get('TOME_E2E_WORKER_CONFIG')
  if not config or not Path(config).is_file(): self.skipTest('candidate config not supplied')
  for seed,expected in ((11,True),(12,False),(13,False),(14,False),(15,False)):
   with self.subTest(case=seed):
    args,timeout,startup=load_config(config); args[2]='/ally_light_fixture.lua'
    bridge=HeadlessBridge(args,timeout,startup); srv=None
    try:
     bridge.start(seed=seed,fixture='exploration'); srv=create_server(ServiceAdapter(bridge),0)
     thread=threading.Thread(target=srv.serve_forever,daemon=True); thread.start()
     conn=http.client.HTTPConnection('127.0.0.1',srv.server_port,timeout=60); conn.request('GET','/api/state')
     response=conn.getresponse(); state=json.loads(response.read()); conn.close(); self.assertEqual(response.status,200)
     self.assertEqual(state['visible_map'][4][18], '1' if expected else '0')
     self.assertEqual(any(e['x']==18 and e['y']==4 for e in state['enemies']),expected)
     self.assertEqual(state['visible_map'][4][22], '0')
     self.assertEqual(state['turn'],0)
    finally:
     if srv: srv.shutdown(); srv.server_close(); thread.join(timeout=2)
     bridge.close()
