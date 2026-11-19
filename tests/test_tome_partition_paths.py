import copy,hashlib,tempfile,unittest
from pathlib import Path
from tests.test_native_partition_store import fixture,blob
from tome_mvp.wasm.session_store import SessionStore,wire

class PartitionPathTests(unittest.TestCase):
 def setUp(self):
  self.tmp=tempfile.TemporaryDirectory();self.store=SessionStore(Path(self.tmp.name)/'x.sqlite',self.tmp.name,native_partitions=True,native_checkpoints=True)
  self.scope={'build':'build','world_id':'world','campaign_id':'campaign'};self.m,self.blobs=fixture()
  self.area={'local_areas':{'outside':True,'current_area':'area:1','areas':{'area:1':{'floors':{'1':{'visited':True}}}}}}
  archive={'format':'tome-partition-session-v1','build':'build','seed':1,'base':{'version':53,'manifest_sha256':hashlib.sha256(wire(self.m).encode()).hexdigest(),'envelope':{}},'audit':[],'events':[],'final':'a'*64}
  with self.store.connect() as db:
   db.execute('INSERT INTO battles VALUES(?,?,?,?,?,?)',('b',52,'active',wire({'build':'build'}),wire({'turn':0,'campaign_bootstrap':True,'status':'active'}),wire({})))
  self.store._commit_partition_candidate('b',52,'seed',self.scope,{'manifest':self.m,'blobs':self.blobs,'archive':archive,'view':{'turn':0,'campaign_bootstrap':True,'status':'active'},'native':self.area})
 def tearDown(self):self.tmp.cleanup()
 def test_browser_read_is_server_selected_and_fake_base_rejected(self):
  result=self.store.partition_checkpoint('b');self.assertEqual(set(result),{'version','manifest','blobs'});self.assertEqual(result['version'],53)
  archive=self.store.get('b')['archive'];archive['base']['manifest_sha256']='0'*64
  with self.assertRaisesRegex(ValueError,'untrusted checkpoint base'):
   self.store.save({'battle_id':'b','version':53,'request_id':'bad','archive':archive,'handover':False})
  self.assertEqual(self.store.get('b')['version'],53)
 def test_character_checkpoint_requires_boundary_and_current_handover(self):
  self.assertEqual(self.store.partition_checkpoint('b',character=True,expected_version=53)['version'],53)
  with self.store.connect() as db:
   db.execute("UPDATE battles SET view=? WHERE id='b'",(wire({'status':'active'}),))
   db.execute("UPDATE battles SET native=? WHERE id='b'",(wire({}),))
  with self.assertRaisesRegex(ValueError,'boundary'):self.store.partition_checkpoint('b',character=True,expected_version=53)
  with self.store.connect() as db:
   db.execute("UPDATE battles SET state='suspended',native=? WHERE id='b'",(wire(self.area),))
   db.execute("INSERT INTO handovers VALUES('h','b',52,'pending','{}')")
  with self.assertRaisesRegex(ValueError,'handover'):self.store.partition_checkpoint('b',character=True,expected_version=53)
  with self.store.connect() as db:db.execute("UPDATE handovers SET version=53 WHERE id='h'")
  self.assertEqual(self.store.partition_checkpoint('b',character=True,expected_version=53)['version'],53)
  with self.assertRaisesRegex(ValueError,'active partition'):self.store.partition_checkpoint('b')
  with self.assertRaisesRegex(ValueError,'boundary'):self.store.partition_checkpoint('b',character=True,expected_version=52)
 def test_unported_write_cannot_call_legacy_validator(self):
  self.store.validator=lambda *_:self.fail('legacy validator was called')
  with self.assertRaisesRegex(ValueError,'unavailable for partition'):
   self.store._legacy_validate(self.store.get('b')['archive'],[])
 def test_area_directory_must_agree_before_vm_launch(self):
  archive=self.store.get('b')['archive']
  with self.store.connect() as db:
   db.execute('BEGIN IMMEDIATE')
   with self.assertRaisesRegex(ValueError,'area directory and partition mismatch'):
    self.store._partition_validate_tx(db,'b',53,archive,[],{'kind':'area','area_id':'a','floor':1})
 def test_wrong_world_is_rejected_before_vm_launch(self):
  archive=self.store.get('b')['archive']
  with self.store.connect() as db:
   db.execute('BEGIN IMMEDIATE')
   with self.assertRaisesRegex(ValueError,'world mismatch'):
    self.store._partition_validate_tx(db,'b',53,archive,[],{'kind':'loadout'},expected_world='other')
 def test_failure_evidence_is_bounded_and_contains_no_blob(self):
  import json
  from unittest.mock import patch
  from types import SimpleNamespace
  archive=self.store.get('b')['archive']
  def rejected(command,**kwargs):
   Path(command[-1]).write_text(json.dumps({'ok':False,'error':'native failed','logs':['line '+str(i) for i in range(30)]}),encoding='utf8')
   return SimpleNamespace(returncode=1)
  with patch('tome_mvp.wasm.session_store.ROOT',Path(self.tmp.name)),patch.object(self.store,'_partition_frozen_host',return_value=Path('fixture.mjs')),patch('tome_mvp.wasm.session_store.subprocess.run',side_effect=rejected):
   with self.store.connect() as db:
    db.execute('BEGIN IMMEDIATE')
    with self.assertRaisesRegex(ValueError,'evidence'):
     self.store._partition_validate_tx(db,'b',53,archive,[],{'kind':'loadout'})
   paths=list((Path(self.tmp.name)/'artifacts/evidence/native-partition-failures').glob('*/failure.json'))
   self.assertEqual(len(paths),1);e=json.loads(paths[0].read_text(encoding='utf8'))
   self.assertEqual(e['version'],53);self.assertEqual(len(e['logs']),30);self.assertEqual(e['error'],'native failed')
   self.assertEqual({x['partition_id'] for x in e['dependencies']},{'hot','z'})
   self.assertNotIn('blobs',e);self.assertNotIn('archive',e)
  self.assertEqual(self.store.get('b')['version'],53)
 def test_host_loadout_publishes_candidate_and_retry(self):
  m=copy.deepcopy(self.m);d,b=blob('updated hot');m['hot_root']['blob_digest']=d
  archive=copy.deepcopy(self.store.get('b')['archive']);archive['base']['version']=54;archive['base']['manifest_sha256']=hashlib.sha256(wire(m).encode()).hexdigest()
  candidate={'manifest':m,'blobs':{d:b},'archive':archive,'view':{'turn':0,'status':'active','campaign_bootstrap':True},'native':self.area}
  calls=[]
  def validate(*args,**kw):calls.append((args,kw));return {'candidate':candidate,'results':[{'accepted':True,'transition':{'operation':'switch_set'}},{'accepted':True,'transition':[]}]}
  self.store._partition_validate_tx=validate
  args=('b',53,'load','world',{'operation':'switch_set'},'tile','obs')
  result=self.store.apply_loadout(*args);self.assertEqual(result['version'],54);self.assertEqual(self.store.apply_loadout(*args),result);self.assertEqual(len(calls),1)
  self.assertEqual(self.store.get('b')['archive'],archive)
  with self.store.connect() as db:self.assertEqual(db.execute('SELECT count(*) FROM native_partition_versions').fetchone()[0],2)

class PartitionHTTPTests(unittest.TestCase):
 def test_http_exposes_only_server_selected_read(self):
  from io import BytesIO
  from tome_mvp.wasm.session_server import SessionAPI
  class Store:
   native_checkpoints=True;_partition_experimental=True
   def partition_checkpoint(self,bid):
    self.seen=bid;return {'version':1,'manifest':{},'blobs':{'hot':'YQ=='}}
  class Handler:
   def __init__(self,data=b''):
    self.headers={'Content-Length':str(len(data))};self.rfile=BytesIO(data);self.wfile=BytesIO();self.status=None
   def send_response(self,n):self.status=n
   def send_header(self,*args):pass
   def end_headers(self):pass
  store=Store();api=SessionAPI(store,'secret');bid='a'*32
  h=Handler();api.http(h,'GET','/api/partition-checkpoints/'+bid)
  self.assertEqual(h.status,200);self.assertEqual(store.seen,bid)
  h=Handler(b'{}');api.http(h,'POST','/api/partition-checkpoints/'+bid)
  self.assertEqual(h.status,404)
  h=Handler();api.http(h,'GET','/api/partition-checkpoints/'+bid+'/floor')
  self.assertEqual(h.status,400)

if __name__=='__main__':unittest.main()
