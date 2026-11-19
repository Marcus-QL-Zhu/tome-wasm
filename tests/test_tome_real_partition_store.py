import json, tempfile, unittest
from pathlib import Path
from tome_mvp.wasm.session_store import SessionStore, wire

SAMPLE=Path('artifacts/native-level-partition-20261115/real-wire-sample.json')

@unittest.skipUnless(SAMPLE.is_file(), 'real VM sample has not been generated')
class RealNativeBundleStorageTests(unittest.TestCase):
    def test_real_native_blobs_in_session_transaction(self):
        source=json.loads(SAMPLE.read_text(encoding='utf8')); m=source['manifest']
        blobs={b['digest']:b['payload_base64'] for b in source['blobs']}
        self.assertEqual(len(blobs),len(source['blobs']))
        scope={k:m[k] for k in ('build','world_id','campaign_id')}
        candidate={'manifest':m,'blobs':blobs,'archive':{'format':'fixture-projection','build':m['build']},'view':{'turn':0},'native':{}}
        with tempfile.TemporaryDirectory() as temp:
            store=SessionStore(Path(temp)/'db.sqlite',temp);store._partition_experimental=True
            with store.connect() as db:
                db.execute('INSERT INTO battles(id,version,state,archive,view,native) VALUES(?,?,?,?,?,?)',('b',7,'active',wire({'build':m['build'],'format':'fixture-old'}),wire({}),wire({})))
            receipt=store._commit_partition_candidate('b',7,'fixture',scope,candidate)
            self.assertEqual(receipt['version'],8)
            manifest,only_hot=store._read_partition_candidate('b',8,['hot'])
            self.assertEqual(manifest,m);self.assertEqual(only_hot['hot'],blobs[m['hot_root']['blob_digest']])
            _,parts=store._read_partition_candidate('b',8,[p['partition_id'] for p in m['partitions']])
            for p in m['partitions']: self.assertEqual(parts[p['partition_id']],blobs[p['blob_digest']])
            with store.connect() as db:
                self.assertEqual(db.execute('SELECT COUNT(*) FROM native_partition_blobs').fetchone()[0],len(blobs))
                self.assertEqual(db.execute('SELECT version FROM native_partition_battle_history').fetchone()[0],7)

if __name__=='__main__': unittest.main()
