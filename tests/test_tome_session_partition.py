import copy
import sqlite3
import tempfile
import unittest
from pathlib import Path
from tests.test_native_partition_store import fixture, blob
from tome_mvp.wasm.session_store import SessionStore, wire

class SessionPartitionTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(); self.path=Path(self.tmp.name)/'sessions.sqlite'
        self.store=SessionStore(self.path,self.tmp.name)
        self.scope={'build':'build','world_id':'world','campaign_id':'campaign'}
        m,b=fixture(); self.candidate={'manifest':m,'blobs':b,'archive':{'build':'build','format':'test-candidate'},'view':{'turn':0},'native':{'party':[]}}
        with self.store.connect() as db:
            db.execute('INSERT INTO battles(id,version,state,archive,view,native) VALUES(?,?,?,?,?,?)',('battle',52,'active',wire({'build':'build','format':'legacy'}),wire({'turn':0}),wire({})))
    def tearDown(self): self.tmp.cleanup()
    def commit(self,version=52,request='req',candidate=None,scope=None):
        return self.store._commit_partition_candidate('battle',version,request,scope or self.scope,candidate or self.candidate)
    def test_default_closed_and_old_battle_unchanged(self):
        with self.assertRaisesRegex(ValueError,'unavailable'): self.commit()
        self.assertEqual(self.store.get('battle')['version'],52)
    def test_atomic_publish_retry_scope_and_hot_read(self):
        self.store._partition_experimental=True
        receipt=self.commit();self.assertEqual(receipt['version'],53)
        self.assertEqual(self.commit(),receipt)
        self.assertEqual(self.store.get('battle')['archive'],self.candidate['archive'])
        with self.store.connect() as db:
            prior=db.execute('SELECT version,archive FROM native_partition_battle_history WHERE battle_id=?',('battle',)).fetchone()
            self.assertEqual(prior[0],52); self.assertIn('legacy',prior[1])
        _,parts=self.store._read_partition_candidate('battle',53,['hot'])
        self.assertEqual(list(parts),['hot'])
        with self.assertRaises(ValueError): self.store._read_partition_candidate('battle',52,['hot'])
        changed=copy.deepcopy(self.candidate);changed['view']['turn']=1
        with self.assertRaisesRegex(ValueError,'conflict'): self.commit(candidate=changed)
        with self.assertRaisesRegex(ValueError,'scope'): self.commit(53,'other',scope={**self.scope,'world_id':'different'})
    def test_failed_battle_update_rolls_back_partition_and_receipt(self):
        self.store._partition_experimental=True
        with self.store.connect() as db:
            db.execute("CREATE TRIGGER reject_candidate BEFORE UPDATE ON battles BEGIN SELECT RAISE(ABORT, 'forced failure'); END")
        with self.assertRaises(sqlite3.IntegrityError): self.commit()
        self.assertEqual(self.store.get('battle')['version'],52)
        with self.store.connect() as db:
            names={r[0] for r in db.execute("SELECT name FROM sqlite_master WHERE type='table'")}
            if 'native_partition_versions' in names: self.assertEqual(db.execute('SELECT COUNT(*) FROM native_partition_versions').fetchone()[0],0)
    def test_missing_blob_or_stale_battle_never_publish(self):
        self.store._partition_experimental=True
        bad=copy.deepcopy(self.candidate);bad['blobs']={}
        with self.assertRaises(ValueError): self.commit(candidate=bad)
        self.assertEqual(self.store.get('battle')['version'],52)
        with self.assertRaises(ValueError): self.commit(version=51)
        self.assertEqual(self.store.get('battle')['version'],52)
    def test_departed_suspended_updates_handover_atomically(self):
        self.store._partition_experimental=True
        outside={'local_areas':{'outside':True,'current_area':'area:1','areas':{'area:1':{}}}}
        self.candidate['native']=outside
        self.candidate['view']={'turn':1}
        with self.store.connect() as db:
            db.execute("UPDATE battles SET state='suspended',native=? WHERE id='battle'",(wire(outside),))
            db.execute("INSERT INTO handovers VALUES(?,?,?,?,?)",('h','battle',52,'pending',wire({'receipt':{'version':52},'view':{'turn':0}})))
        self.assertEqual(self.commit()['version'],53)
        with self.store.connect() as db:
            version,stored=db.execute("SELECT version,receipt FROM handovers WHERE id='h'").fetchone()
            import json
            saved=json.loads(stored)
            self.assertEqual((version,saved['receipt']['version'],saved['view']['turn']),(53,53,1))
            self.assertEqual(db.execute("SELECT state FROM battles WHERE id='battle'").fetchone()[0],'suspended')
            prior=db.execute('SELECT version,receipt FROM native_partition_handover_history').fetchone()
            self.assertEqual((prior[0],json.loads(prior[1])['receipt']['version']),(52,52))
    def test_missing_handover_or_invalid_candidate_cannot_publish(self):
        self.store._partition_experimental=True
        outside={'local_areas':{'outside':True,'current_area':'area:1','areas':{'area:1':{}}}}
        self.candidate['native']=outside
        with self.store.connect() as db:
            db.execute("UPDATE battles SET state='suspended',native=? WHERE id='battle'",(wire(outside),))
        with self.assertRaisesRegex(ValueError,'handover'): self.commit()
        with self.store.connect() as db:
            db.execute("INSERT INTO handovers VALUES(?,?,?,?,?)",('h','battle',52,'pending',wire({'receipt':{'version':52},'view':{}})))
        self.candidate['native']={}
        with self.assertRaisesRegex(ValueError,'safe departed'): self.commit()
        self.assertEqual(self.store.get('battle')['version'],52)
    def test_failed_handover_update_rolls_back_everything(self):
        self.store._partition_experimental=True
        outside={'local_areas':{'outside':True,'current_area':'area:1','areas':{'area:1':{}}}}
        self.candidate['native']=outside
        with self.store.connect() as db:
            db.execute("UPDATE battles SET state='suspended',native=? WHERE id='battle'",(wire(outside),))
            db.execute("INSERT INTO handovers VALUES(?,?,?,?,?)",('h','battle',52,'pending',wire({'receipt':{'version':52},'view':{}})))
            db.execute("CREATE TRIGGER reject_handover BEFORE UPDATE ON handovers BEGIN SELECT RAISE(ABORT, 'forced failure'); END")
        with self.assertRaises(sqlite3.IntegrityError): self.commit()
        self.assertEqual(self.store.get('battle')['version'],52)
        with self.store.connect() as db: self.assertEqual(db.execute("SELECT version FROM handovers WHERE id='h'").fetchone()[0],52)
    def test_inactive_battle_rejected(self):
        self.store._partition_experimental=True
        with self.store.connect() as db: db.execute("UPDATE battles SET state='suspended' WHERE id='battle'")
        with self.assertRaisesRegex(ValueError,'safe departed'): self.commit()
        self.assertEqual(self.store.get('battle')['version'],52)

if __name__=='__main__': unittest.main()

