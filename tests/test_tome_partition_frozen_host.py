import hashlib,json,tempfile,unittest
from pathlib import Path
from tome_mvp.wasm.session_store import SessionStore

class FrozenPartitionHostTests(unittest.TestCase):
 def setUp(self):
  self.tmp=tempfile.TemporaryDirectory();self.base=Path(self.tmp.name);self.public=self.base/'public';self.public.mkdir();(self.base/'host').mkdir()
  names=['host/tome_partition_host.mjs','host/tome_partition_migrate.mjs','host/tome_partition_candidate.mjs','host/tome_validate_operations.mjs','host/partition_session_host.mjs','host/partition_transport.mjs','public/battle_session.mjs','public/engine_bridge.mjs','public/kernel_runtime.mjs','public/encounter_overlay.mjs','public/partition_session.mjs','public/partition_transport.mjs']
  descriptors={}
  for name in names:
   raw=('fixture '+name).encode();(self.base/name).write_bytes(raw);descriptors[name]={'sha256':hashlib.sha256(raw).hexdigest(),'bytes':len(raw)}
  outputs={}
  for name in ('tome.js','tome.wasm','tome.data'):
   raw=('binary '+name).encode();(self.public/name).write_bytes(raw);outputs[name]={'sha256':hashlib.sha256(raw).hexdigest(),'bytes':len(raw)}
  self.inputs={'host_scripts':descriptors};self.build=hashlib.sha256(json.dumps(self.inputs,sort_keys=True).encode()).hexdigest()[:16]
  (self.base/'identity.json').write_text(json.dumps({'build_id':self.build,'inputs':self.inputs}),encoding='utf8');(self.base/'build.json').write_text(json.dumps({'outputs':outputs}),encoding='utf8')
  self.store=SessionStore(self.base/'battle.sqlite',self.public,native_partitions=True)
 def tearDown(self):self.tmp.cleanup()
 def test_exact_package_accepted(self):
  self.assertEqual(self.store._partition_frozen_host('tome_partition_host.mjs',self.build),self.base/'host/tome_partition_host.mjs')
 def test_workspace_root_is_not_a_fallback(self):
  from unittest.mock import patch
  with patch('tome_mvp.wasm.session_store.ROOT',self.base/'different_workspace'):
   self.assertEqual(self.store._partition_frozen_host('tome_partition_host.mjs',self.build),self.base/'host/tome_partition_host.mjs')
 def test_tampered_or_missing_dependency_rejected(self):
  target=self.base/'host/tome_partition_candidate.mjs';original=target.read_bytes();target.write_bytes(original+b'x')
  with self.assertRaisesRegex(ValueError,'dependency mismatch'):self.store._partition_frozen_host('tome_partition_host.mjs',self.build)
  target.write_bytes(original);target.unlink()
  with self.assertRaisesRegex(ValueError,'dependencies unavailable'):self.store._partition_frozen_host('tome_partition_host.mjs',self.build)
 def test_identity_and_binary_tampering_rejected(self):
  with self.assertRaisesRegex(ValueError,'identity mismatch'):self.store._partition_frozen_host('tome_partition_host.mjs','bad')
  (self.public/'tome.wasm').write_bytes(b'wrong')
  with self.assertRaisesRegex(ValueError,'binary size mismatch'):self.store._partition_frozen_host('tome_partition_host.mjs',self.build)
 def test_tamper_fails_before_battle_or_manifest_write(self):
  from tome_mvp.wasm.session_store import wire
  from tests.test_native_partition_store import fixture
  m,blobs=fixture();m['build']=self.build;scope={k:m[k] for k in ('build','world_id','campaign_id')}
  archive={'format':'tome-partition-session-v1','build':self.build,'seed':1,'base':{'version':1,'manifest_sha256':hashlib.sha256(wire(m).encode()).hexdigest(),'envelope':{}},'audit':[],'events':[],'final':'a'*64}
  with self.store.connect() as db:db.execute('INSERT INTO battles VALUES(?,?,?,?,?,?)',('b',0,'active',wire({'build':self.build}),wire({'turn':0}),wire({})))
  self.store._commit_partition_candidate('b',0,'seed',scope,{'manifest':m,'blobs':blobs,'archive':archive,'view':{'turn':0,'campaign_bootstrap':True,'status':'active'},'native':{}})
  (self.base/'host/tome_partition_candidate.mjs').write_bytes(b'tampered')
  with self.assertRaisesRegex(ValueError,'dependency mismatch'):
   self.store.apply_loadout('b',1,'try','world',{'operation':'switch_set'},'tile','obs')
  self.assertEqual(self.store.get('b')['version'],1)
  with self.store.connect() as db:
   self.assertEqual(db.execute('select count(*) from native_partition_versions').fetchone()[0],1)
   self.assertIsNone(db.execute("select 1 from receipts where request_id='try'").fetchone())
 def test_missing_descriptor_cannot_fallback(self):
  (self.base/'identity.json').write_text(json.dumps({'build_id':self.build,'inputs':{}}),encoding='utf8')
  with self.assertRaises(ValueError):self.store._partition_frozen_host('tome_partition_host.mjs',self.build)

if __name__=='__main__':unittest.main()
