from copy import deepcopy
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from tome_mvp.wasm.session_store import SessionStore

class NativeAdmissionTest(unittest.TestCase):
 def test_trusted_base_incremental_and_rollback(self):
  with tempfile.TemporaryDirectory() as tmp:
   calls=[]
   base={'checkpoint':{'format':'tome-native-save-v1','blob':'trusted'},'bridge':{},'final':'initial'}
   def validate(archive,operations):
    calls.append(deepcopy(archive))
    return {'archive':{'format':'tome-native-session-v1','build':'b','seed':7,'base':deepcopy(base),'audit':[],'events':[],'final':'initial'},'view':{'turn':0,'status':'active'}}
   store=SessionStore(Path(tmp)/'s.db',tmp,validate,native_checkpoints=True)
   legacy={'format':'tome-replay-save-v1','build':'b','seed':7,'events':[]}
   first=store.save({'request_id':'first','version':0,'archive':legacy,'handover':False})
   doc=store.get(first['battle_id'])['archive'];doc['events'].append({'kind':'command','body':{},'digest':'ok'});doc['final']='next'
   forged=deepcopy(doc);forged['base']['checkpoint']['blob']='forged'
   req={'request_id':'second','battle_id':first['battle_id'],'version':1,'archive':forged,'handover':False}
   with self.assertRaisesRegex(ValueError,'untrusted'):store.save(req)
   self.assertEqual(len(calls),1);self.assertEqual(store.get(first['battle_id'])['version'],1)
   req['archive']=doc;result=store.save(req);self.assertEqual(result['version'],2);self.assertEqual(len(calls),2)
   self.assertEqual(store.save(req),result);self.assertEqual(len(calls),2)
 def test_oversize_utf8_blob_rejected_without_commit(self):
  with tempfile.TemporaryDirectory() as tmp:
   store=SessionStore(Path(tmp)/'s.db',tmp,lambda a,o: (_ for _ in ()).throw(AssertionError('validation called')),native_checkpoints=True)
   doc={'format':'tome-native-session-v1','events':[],'base':{'checkpoint':{'blob':'汉汉'}}}
   with patch('tome_mvp.wasm.session_store.NATIVE_BLOB_LIMIT',5):
    with self.assertRaisesRegex(ValueError,'blob capacity'):
     store.save({'request_id':'one','version':0,'handover':False,'archive':doc})
   with store.connect() as db:self.assertEqual(db.execute('SELECT count(*) FROM battles').fetchone()[0],0)
 def test_feature_gate_rejects_native_initial(self):
  with tempfile.TemporaryDirectory() as tmp:
   store=SessionStore(Path(tmp)/'s.db',tmp,lambda a,o:{},native_checkpoints=False)
   with self.assertRaisesRegex(ValueError,'unavailable'):
    store.save({'request_id':'one','version':0,'handover':False,'archive':{'format':'tome-native-session-v1','events':[]}})

if __name__=='__main__':unittest.main()
