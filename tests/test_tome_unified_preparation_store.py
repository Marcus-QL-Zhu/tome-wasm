import json
from unittest.mock import Mock

import pytest
from tome_mvp.wasm.session_store import SessionStore, wire

ENTRIES=[{'enemy_id':'thieve:X','count':2,'difficulty':'hard','same_room':True}]

def setup(tmp_path, mode='ok', native=None):
    calls=[]
    def validate(archive,operations):
        calls.append(operations)
        results=[]
        for i,op in enumerate(operations):
            transition={'status':'applied','actor_id':i+10,'level':op.get('reference_level',23),'x':i+1,'y':2,'placement':op['placement'],'enemy_id':op.get('enemy_id','thieve:X')}
            if 'person_id' in op:transition['person_id']=op['person_id']
            results.append({'accepted':True,'transition':transition})
        if mode=='rejected':results[1]['transition']['status']='rejected'
        if mode=='missing':results.pop()
        return {'archive':{'new':True},'view':{'turn':8 if mode=='turn' else 7,'status':'active'},'native':native or {},'results':results}
    store=SessionStore(tmp_path/'battle.db',tmp_path,validate)
    with store.connect() as db:
        db.execute('INSERT INTO battles(id,version,state,archive,view,native) VALUES(?,?,?,?,?,?)',('battle',3,'active',wire({'old':True}),wire({'turn':7,'status':'active'}),wire(native or {})))
    return store,calls

def snapshot(store):
    with store.connect() as db:
        return db.execute('SELECT * FROM battles').fetchall(),db.execute('SELECT * FROM receipts').fetchall()

@pytest.mark.parametrize('mode',['rejected','missing','turn'])
def test_batch_failure_is_atomic(tmp_path,mode):
    store,calls=setup(tmp_path,mode);before=snapshot(store)
    with pytest.raises(ValueError):store.prepare_enemies('battle',3,'request',ENTRIES,base_reference_level=10)
    assert snapshot(store)==before and len(calls)==1 and len(calls[0])==2

def test_batch_single_commit_retry_and_conflict(tmp_path):
    store,calls=setup(tmp_path)
    receipt=store.prepare_enemies('battle',3,'request',ENTRIES,base_reference_level=10)
    assert receipt['version']==4 and len(receipt['enemies'])==2 and all(x['level']==12 for x in receipt['enemies'])
    assert store.get('battle')['version']==4
    assert store.prepare_enemies('battle',3,'request',ENTRIES,base_reference_level=10)==receipt and len(calls)==1
    with pytest.raises(ValueError):store.prepare_enemies('battle',3,'request',ENTRIES,base_reference_level=11)
    assert len(calls)==1 and len(snapshot(store)[1])==1

def test_existing_person_source_and_level_are_preserved(tmp_path):
    native={'world_people':{'person-1':{'status':'alive','area_id':'area:old','floor':2}},'local_areas':{'current_area':'area:new','current_floor':1}}
    store,calls=setup(tmp_path,native=native)
    original=store._partition_or_legacy_tx; scopes=[]
    def spy(*args,**kwargs):scopes.append(kwargs['selection']);return original(*args,**kwargs)
    store._partition_or_legacy_tx=spy
    result=store.prepare_enemies('battle',3,'person-request',[{'person_id':'person-1','person_name':'Trusted','count':1,'difficulty':'easy','same_room':True}],base_reference_level=10)
    op=calls[0][0]
    assert op['source_area']=='area:old' and op['source_floor']==2
    assert 'reference_level' not in op and 'enemy_id' not in op
    assert scopes[0]['sources']==[{'area_id':'area:old','floor':2}] and result['enemies'][0]['level']==23


def test_surrendered_living_person_can_fight_again_without_recreation(tmp_path):
    native={'world_people':{'person-1':{'status':'surrendered','area_id':'area:old','floor':1}},'local_areas':{'current_area':'area:new','current_floor':1}}
    store,calls=setup(tmp_path,native=native)
    store.prepare_enemies('battle',3,'fight-again',[{'person_id':'person-1','person_name':'Known'}],base_reference_level=50)
    assert 'reference_level' not in calls[0][0] and 'enemy_id' not in calls[0][0]


def test_trusted_new_roster_can_reopen_cleared_persistent_area(tmp_path):
    native={'local_areas':{'current_area':'area:old','current_floor':1}}
    store,calls=setup(tmp_path,native=native)
    with store.connect()as db:
        db.execute('UPDATE battles SET view=? WHERE id=?',(wire({'turn':7,'status':'victory','mission_complete':True,'map_available':True}),'battle'))
    assert store.prepare_enemies('battle',3,'new-roster',ENTRIES,base_reference_level=10)['status']=='applied'


@pytest.mark.parametrize('internal',['person_id','person_name','reference_level','source_area','source_floor'])
def test_resume_cannot_supply_trusted_identity_fields(tmp_path,internal):
    store,calls=setup(tmp_path)
    op={'operation':'spawn_enemy','operation_id':'injected','enemy_id':'orc:WARRIOR','placement':'same_room',internal:'fake'}
    with pytest.raises(ValueError,match='unified trusted entry'):
        store.resolve('handover','injected-request',[op])
    assert not calls

def test_old_job_cannot_reopen_shared_run_during_new_preparation(tmp_path):
    from types import SimpleNamespace
    from dm_mvp.generic_runtime import AsyncWasmGateway
    gateway=AsyncWasmGateway(tmp_path/'jobs',SimpleNamespace())
    scope={'campaign_id':'c','world_id':'w','owner_id':'o'}
    launch=wire({'id':'a'*32,'battle_id':'b'*32})
    with gateway._db() as db:
        db.execute('INSERT INTO dm_wasm_jobs VALUES(?,?,?,?,?,?,?,?)',('old','c','w','o','old-action','{}','ready',launch))
        db.execute('INSERT INTO dm_wasm_jobs VALUES(?,?,?,?,?,?,?,?)',('new','c','w','o','new-action','{}','preparing',None))
    assert gateway.status(**scope,job_id='old')['access_blocked'] is True
    with pytest.raises(ValueError):gateway.binding(**scope,job_id='old')
    with gateway._db() as db: db.execute("UPDATE dm_wasm_jobs SET state='unknown' WHERE id='new'")
    with pytest.raises(ValueError):gateway.binding(**scope,job_id='old')
    with gateway._db() as db: db.execute("UPDATE dm_wasm_jobs SET state='ready',launch=? WHERE id='new'",(launch,))
    assert gateway.binding(**scope,job_id='old')['id']=='a'*32
    gateway.close()
