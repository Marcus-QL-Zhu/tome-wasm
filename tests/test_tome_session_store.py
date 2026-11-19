from copy import deepcopy
from pathlib import Path
import tempfile
import unittest
from tome_mvp.wasm.session_store import SessionStore


class SessionStoreTests(unittest.TestCase):
 def setUp(self):
  self.temp=tempfile.TemporaryDirectory();self.root=Path(self.temp.name);self.calls=0
  def validate(archive,operations):
   self.calls+=1;doc=deepcopy(archive)
   for op in operations:doc['events'].append({'kind':'dm_transition','body':op,'digest':'test-only'})
   return {'archive':doc,'view':{'turn':42,'status':'active','party':[{'id':1,'hp':20}]}}
  self.store=SessionStore(self.root/'store.sqlite',self.root,validate)
  self.archive={'format':'tome-replay-save-v1','build':'test-only','seed':23,'events':[]}
 def tearDown(self):self.temp.cleanup()
 def save(self,**extra):return self.store.save({'request_id':'save1','version':0,'handover':True,'archive':deepcopy(self.archive),**extra})
 def test_save_is_durable_and_idempotent(self):
  r=self.save();self.assertEqual(r,self.save());self.assertEqual(self.calls,1)
  self.assertEqual(self.store.get(r['battle_id'])['state'],'suspended');self.assertEqual(len(self.store.pending()),1)
  with self.assertRaises(ValueError):self.save(handover=False)
 def test_nonterminal_resolution_keeps_same_battle(self):
  r=self.save();op={'operation':'recruit','operation_id':'op1','target':'22'}
  result=self.store.resolve(r['handover_id'],'resolve1',[op]);self.assertEqual(result['battle_id'],r['battle_id']);self.assertEqual(result['version'],2)
  self.assertEqual(result,self.store.resolve(r['handover_id'],'resolve1',[op]));self.assertEqual(self.store.pending(),[])
  current=self.store.get(r['battle_id']);self.assertEqual(current['state'],'active');self.assertEqual(current['archive']['events'][0]['body'],op)
 def test_forged_dm_changes_and_stale_writes_are_rejected(self):
  forged=deepcopy(self.archive);forged['events']=[{'kind':'dm_transition','body':{'operation':'recruit'},'digest':'fake'}]
  with self.assertRaises(ValueError):self.save(archive=forged)
  r=self.save(handover=False)
  with self.assertRaises(ValueError):self.save(request_id='stale',battle_id=r['battle_id'])
 def test_resolved_archive_can_continue_without_duplicate_recruitment(self):
  r=self.save();self.store.resolve(r['handover_id'],'resolve1',[{'operation':'recruit','operation_id':'op1','target':'22'}])
  current=self.store.get(r['battle_id']);doc=deepcopy(current['archive']);doc['events'].append({'kind':'command','body':{'type':'wait'},'digest':'next'})
  saved=self.save(request_id='save2',battle_id=r['battle_id'],version=2,archive=doc,handover=False)
  self.assertEqual(saved['version'],3)

if __name__=='__main__':unittest.main()
