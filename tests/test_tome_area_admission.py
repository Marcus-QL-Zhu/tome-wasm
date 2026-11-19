from copy import deepcopy
import tempfile
from pathlib import Path
import unittest

from tome_mvp.wasm.session_store import SessionStore, scene_number, wire


class AreaAdmissionTests(unittest.TestCase):
    def setUp(self):
        root=Path(__file__).resolve().parents[1]/'artifacts'
        self.temp=tempfile.TemporaryDirectory(dir=root,prefix='area-admission-')
        self.calls=[]
        self.fail=False
        self.archive={'format':'tome-native-session-v1','build':'isolated','seed':1,'base':{},'audit':[],'events':[]}
        self.view={'turn':10,'status':'active'}

        def validate(archive,operations):
            self.calls.append(deepcopy(operations))
            if self.fail:
                raise ValueError('isolated candidate failure')
            doc=deepcopy(archive)
            doc['audit'].append({'kind':'dm_transition','body':operations[0]})
            return {'ok':True,'archive':doc,'view':deepcopy(self.view),'native':{'party':[]},
                    'results':[{'accepted':True,'transition':{'area_id':operations[0]['area'].get('area_id')}}]}

        self.store=SessionStore(Path(self.temp.name)/'db.sqlite',self.temp.name,validate,native_checkpoints=True)
        with self.store.connect()as db:
            db.execute('INSERT INTO battles VALUES(?,?,?,?,?,?)',('b',1,'active',wire(self.archive),wire(self.view),'{}'))
        self.area={'area_id':'area:isolated','floor':1,'floor_count':2,
                   'world_clock':{'world_tick':4,'day_in_quarter':0}}

    def tearDown(self):
        self.temp.cleanup()

    def test_commit_retry_conflict(self):
        r=self.store.apply_area('b',1,'enter','area_enter',self.area)
        self.assertEqual(r['version'],2)
        self.assertEqual(r,self.store.apply_area('b',1,'enter','area_enter',self.area))
        self.assertEqual(len(self.calls),1)
        bad={**self.area,'floor':2}
        with self.assertRaisesRegex(ValueError,'conflict'):
            self.store.apply_area('b',1,'enter','area_enter',bad)
        self.assertEqual(self.store.get('b')['version'],2)

    def test_native_failure_keeps_archive_and_version(self):
        before=self.store.get('b');self.fail=True
        with self.assertRaisesRegex(ValueError,'candidate failure'):
            self.store.apply_area('b',1,'enter','area_enter',self.area)
        self.assertEqual(self.store.get('b'),before)
        with self.store.connect()as db:
            self.assertEqual(db.execute('SELECT count(*) FROM receipts').fetchone()[0],0)

    def test_clock_and_floor_rejected_before_validation(self):
        for bad in ({**self.area,'floor':3},
                    {**self.area,'world_clock':{'world_tick':4,'day_in_quarter':90}}):
            with self.assertRaises(ValueError):
                self.store.apply_area('b',1,'enter','area_enter',bad)
        self.assertEqual(self.calls,[])

    def test_scene_scope_includes_native_area_entries(self):
        doc={'audit':[{'kind':'campaign_next'},
                      {'kind':'dm_transition','body':{'operation':'area_enter'}},
                      {'kind':'dm_transition','body':{'operation':'area_depart'}}],
             'events':[{'kind':'command','body':{'type':'wait'}}]}
        self.assertEqual(scene_number(doc),2)
