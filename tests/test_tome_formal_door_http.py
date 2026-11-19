"""Native formal door bump through the actual HTTP service."""
import http.client
import json
import os
from pathlib import Path
import threading
import unittest
from tome_mvp.headless_bridge import HeadlessBridge, load_config
from tome_mvp.server import create_server
from tome_mvp.service import ServiceAdapter


class FormalDoorHTTP(unittest.TestCase):
 def test_open_door_and_reject_wall(self):
  config=os.environ.get('TOME_E2E_WORKER_CONFIG')
  if not config or not Path(config).is_file(): self.skipTest('candidate config not supplied')
  args,timeout,startup=load_config(config)
  args[2]='/formal_door_fixture.lua'
  bridge=HeadlessBridge(args,timeout,startup)
  srv=None
  try:
   bridge.start(seed=11,fixture='formal')
   service=ServiceAdapter(bridge)
   srv=create_server(service,0)
   thread=threading.Thread(target=srv.serve_forever,daemon=True); thread.start()
   host=f'127.0.0.1:{srv.server_port}'
   def request(method,path,data=None):
    conn=http.client.HTTPConnection('127.0.0.1',srv.server_port,timeout=60)
    headers={'Origin':'http://'+host,'Content-Type':'application/json'} if data is not None else {}
    conn.request(method,path,json.dumps(data) if data is not None else None,headers)
    response=conn.getresponse(); body=json.loads(response.read()); status=response.status; conn.close()
    return status,body
   status,before=request('GET','/api/state'); self.assertEqual(status,200)
   p=next(x for x in before['party'] if x['id']==before['control_actor_id'])
   near=[(dx,dy) for dx,dy in ((1,0),(-1,0),(0,1),(0,-1)) if before['map'][p['y']+dy][p['x']+dx]=='+']
   self.assertTrue(near,'no visible adjacent native door')
   dx,dy=near[0]
   status,after=request('POST','/api/command',{'type':'move','dx':dx,'dy':dy,'revision':before['revision']})
   self.assertEqual(status,200,after)
   self.assertNotEqual(after['map'][p['y']+dy][p['x']+dx],'+')
   self.assertEqual(after['turn'],before['turn']) # upstream opens this door without spending energy
   self.assertEqual((after['party'][0]['x'],after['party'][0]['y']),(p['x'],p['y']))
   walls=[(x,y) for x,y in ((1,0),(-1,0),(0,1),(0,-1)) if after['map'][p['y']+y][p['x']+x]=='#']
   if walls:
    wx,wy=walls[0]
    status,rejected=request('POST','/api/command',{'type':'move','dx':wx,'dy':wy,'revision':after['revision']})
    self.assertNotEqual(status,200,rejected)
  finally:
   if srv:
    srv.shutdown(); srv.server_close(); thread.join(timeout=2)
   bridge.close()
