from copy import deepcopy
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest

from tome_mvp.wasm.session_store import SessionStore


class PlacementStoreTests(unittest.TestCase):
    def test_incomplete_native_receipts_and_rejected_batches_do_not_write(self):
        with TemporaryDirectory()as tmp:
            result={'ok':True,'archive':{'events':[]},'view':{'turn':0,'status':'active'},'native':{},'results':[]}
            store=SessionStore(Path(tmp)/'sessions.sqlite',tmp,validator=lambda archive,ops:deepcopy(result))
            saved=store.save({'request_id':'initial','version':0,'archive':{'events':[]},'handover':True})
            bid=saved['battle_id'];before=store.get(bid)
            op={'operation':'spawn_enemy','operation_id':'one','enemy_id':'thieve:THIEF_BANDIT','placement':'same_room'}
            for rows in [[],[{'accepted':True,'transition':None}],[{'accepted':True,'transition':{}}]]:
                result['results']=rows
                with self.assertRaises(ValueError):store.place_enemy(bid,1,'one',op)
                self.assertEqual(store.get(bid),before)
            result['results']=[{'accepted':False,'transition':{'status':'applied'}}]
            with self.assertRaisesRegex(ValueError,'enemy placement was rejected'):store.resolve(saved['handover_id'],'bad',[op])
            self.assertEqual(store.get(bid),before);self.assertEqual(len(store.pending()),1)
            result['results']=[{'accepted':True,'transition':{'status':'applied'}}];result['view']['turn']=1
            with self.assertRaisesRegex(ValueError,'placement advanced game time'):store.resolve(saved['handover_id'],'bad',[op])
            self.assertEqual(store.get(bid),before)


if __name__=='__main__':unittest.main()
