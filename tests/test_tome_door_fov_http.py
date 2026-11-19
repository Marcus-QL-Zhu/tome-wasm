"""A native zero-energy door updates visible terrain through the HTTP API."""
import http.client
import json
import os
from pathlib import Path
import threading
import unittest
from tome_mvp.headless_bridge import HeadlessBridge, load_config
from tome_mvp.server import create_server
from tome_mvp.service import ServiceAdapter

class DoorFovHTTP(unittest.TestCase):
 def test_native_door_reveals_beyond_without_tick(self):
  config=os.environ.get('TOME_E2E_WORKER_CONFIG')
  if not config or not Path(config).is_file(): self.skipTest('candidate config not supplied')
  args,timeout,startup=load_config(config); args[2]='/door_fov_fixture.lua'
  bridge=HeadlessBridge(args,timeout,startup); srv=None
  try:
   bridge.start(seed=12,fixture='formal'); srv=create_server(ServiceAdapter(bridge),0)
   thread=threading.Thread(target=srv.serve_forever,daemon=True); thread.start()
   def request(method,path,data=None):
    conn=http.client.HTTPConnection('127.0.0.1',srv.server_port,timeout=60)
    headers={'Origin':f'http://127.0.0.1:{srv.server_port}','Content-Type':'application/json'} if data is not None else {}
    conn.request(method,path,json.dumps(data) if data is not None else None,headers)
    res=conn.getresponse(); body=json.loads(res.read()); status=res.status; conn.close(); return status,body
   status,before=request('GET','/api/state'); self.assertEqual(status,200)
   p=next(a for a in before['party'] if a['id']==before['control_actor_id'])
   near=[(dx,dy) for dx,dy in ((1,0),(-1,0),(0,1),(0,-1)) if before['map'][p['y']+dy][p['x']+dx]=='+' and before['visible_map'][p['y']+2*dy][p['x']+2*dx]=='0']
   self.assertTrue(near,'no door with unseen tile behind')
   dx,dy=near[0]; status,after=request('POST','/api/command',{'type':'move','dx':dx,'dy':dy,'revision':before['revision']})
   self.assertEqual(status,200,after); self.assertEqual(after['visible_map'][p['y']+2*dy][p['x']+2*dx],'1')
   self.assertEqual(after['turn'],before['turn']); q=next(a for a in after['party'] if a['id']==before['control_actor_id']); self.assertEqual((q['x'],q['y']),(p['x'],p['y']))
  finally:
   if srv: srv.shutdown(); srv.server_close(); thread.join(timeout=2)
   bridge.close()


