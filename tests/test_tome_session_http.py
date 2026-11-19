from copy import deepcopy
import json
from pathlib import Path
import tempfile
import threading
import unittest
from urllib.request import Request, urlopen
from urllib.error import HTTPError
from tome_mvp.wasm.serve import create_server
from tome_mvp.wasm.session_store import SessionStore
from tome_mvp.wasm.session_server import SessionAPI


class SessionHTTPTests(unittest.TestCase):
 def test_application_transport_keeps_frozen_native_files(self):
  with tempfile.TemporaryDirectory() as temp:
   root=Path(temp)/'package/public';root.mkdir(parents=True)
   (root.parent/'identity.json').write_text(json.dumps({'build_id':'frozen-build','encounter_overlay':True}))
   original="new BattleSession(kernel.rpc,recorder.build,123)"
   (root/'browser_worker.mjs').write_text(original)
   (root/'kernel_runtime.mjs').write_text('frozen native rules')
   runtime=Path(__file__).resolve().parents[1]/'tome_mvp/wasm'
   server=create_server(root,0,asset_archives=[],runtime_assets=runtime)
   thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
   base=f'http://127.0.0.1:{server.server_port}'
   try:
    with urlopen(base+'/browser_worker.mjs') as response:worker=response.read().decode()
    self.assertIn("new DiagnosticRecorder('frozen-build')",worker)
    self.assertIn('recorder.build,123)',worker)
    self.assertIn("'enabled'==='enabled'",worker)
    self.assertIn('exportBrowserCheckpoint',worker)
    with urlopen(base+'/browser_checkpoint.mjs') as response:self.assertIn(b'partition_export',response.read())
    with urlopen(base+'/kernel_runtime.mjs') as response:self.assertEqual(response.read(),b'frozen native rules')
    self.assertEqual((root/'browser_worker.mjs').read_text(),original)
    self.assertFalse((root/'browser_checkpoint.mjs').exists())
   finally:server.shutdown();server.server_close();thread.join()

 def test_handover_query_resume_and_host_authorization(self):
  with tempfile.TemporaryDirectory() as temp:
   root=Path(temp);(root/'dm.html').write_text('handover page',encoding='utf-8')
   def validate(archive,operations):
    return {'archive':deepcopy(archive),'view':{'turn':42,'status':'active','party':[]}}
   store=SessionStore(root/'state.sqlite',root,validate)
   server=create_server(root,0,assets=root/'images',asset_archives=[],session_api=SessionAPI(store,'test-host-token'))
   thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
   base=f'http://127.0.0.1:{server.server_port}'
   def request(path,data=None,host=False):
    headers={'Content-Type':'application/json'}
    if host:headers['Authorization']='Bearer test-host-token'
    return urlopen(Request(base+path,data=json.dumps(data).encode() if data is not None else None,headers=headers),timeout=3)
   try:
    with request('/dm.html?battle=example') as r:self.assertEqual(r.read(),b'handover page')
    with self.assertRaises(HTTPError) as err:request('/api/dm/handovers')
    self.assertEqual(err.exception.code,403)
    with request('/api/checkpoints',{'request_id':'first','version':0,'handover':True,'archive':{'seed':7,'build':'test','events':[]}}) as r:saved=json.load(r)
    self.assertEqual(saved['state'],'suspended')
    with request('/api/dm/handovers',host=True) as r:self.assertEqual(len(json.load(r)['handovers']),1)
    with request('/api/dm/resolve',{'request_id':'resume','handover_id':saved['handover_id'],'operations':[]},True) as r:resumed=json.load(r)
    self.assertEqual(resumed['battle_id'],saved['battle_id']);self.assertEqual(resumed['resume_url'],'/?battle='+saved['battle_id'])
   finally:server.shutdown();server.server_close();thread.join()


if __name__=='__main__':unittest.main()
