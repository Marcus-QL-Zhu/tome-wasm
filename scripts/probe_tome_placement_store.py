"""Isolated real Wasm replay through the persistent host placement entry."""
import argparse
import json
from pathlib import Path
import sys
import time

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT))
from tome_mvp.wasm.session_store import SessionStore


def main():
    p=argparse.ArgumentParser();p.add_argument('--package',type=Path,required=True);p.add_argument('--output',type=Path,required=True)
    a=p.parse_args();a.output.mkdir(parents=True,exist_ok=False);started=time.monotonic()
    store=SessionStore(a.output/'sessions.sqlite',a.package/'public')
    initial=json.loads((a.package/'probe/initial-archive.json').read_text())
    saved=store.save({'request_id':'initial','version':0,'archive':initial,'handover':True})
    bid=saved['battle_id'];before=store.get(bid)
    query=store.inspect_scene(bid,{'source':'thieve','include_tiles':True})
    assert store.get(bid)==before,'read-only map query changed the authoritative checkpoint'
    receipts=[]
    for i in range(4):
        op={'operation':'spawn_enemy','operation_id':'host-spawn-'+str(i),'enemy_id':'thieve:THIEF_BANDIT','placement':'same_room'}
        r=store.place_enemy(bid,store.get(bid)['version'],op['operation_id'],op);receipts.append(r)
        assert r['status']=='applied'
        assert store.place_enemy(bid,store.get(bid)['version'],op['operation_id'],op)==r
    after=store.get(bid)
    assert after['state']=='suspended' and after['view']['turn']==before['view']['turn']
    assert len(after['native']['enemies'])==len(before['native']['enemies'])+4
    assert after['version']==before['version']+4
    assert len({r['placement']['actor_id']for r in receipts})==4
    with store.connect()as db:
        h=db.execute('SELECT version,state,receipt FROM handovers WHERE battle_id=?',(bid,)).fetchone()
    assert h[0]==after['version'] and h[1]=='pending'
    handover=json.loads(h[2]);assert handover['receipt']['version']==after['version']
    hid=saved['handover_id'];assert hid==handover['receipt']['handover_id']
    # Rejected placement cannot consume a version or resolve the pending handover.
    bad={'operation':'spawn_enemy','operation_id':'occupied','enemy_id':'thieve:THIEF_BANDIT','placement':'exact','x':query['player']['x'],'y':query['player']['y']}
    rejected=store.place_enemy(bid,after['version'],'occupied',bad)
    assert rejected['status']=='rejected'and store.get(bid)==after
    try:store.resolve(hid,'bad-resume',[bad])
    except ValueError as error:assert str(error)=='enemy placement was rejected',str(error)
    else:raise AssertionError('rejected spawn incorrectly resolved the handover')
    assert store.get(bid)==after
    with store.connect()as db:
        h2=db.execute('SELECT version,state,receipt FROM handovers WHERE battle_id=?',(bid,)).fetchone();assert h2==h
        assert db.execute("SELECT count(*) FROM receipts WHERE request_id IN ('occupied','bad-resume')").fetchone()[0]==0
    resumed=store.resolve(hid,'resume-ok',[]);assert resumed['state']=='active'
    assert store.resolve(hid,'resume-ok',[])==resumed
    reopened=SessionStore(store.path,a.package/'public').get(bid)
    assert reopened['version']==after['version']+1 and reopened['state']=='active'
    assert reopened['view']['turn']==after['view']['turn'] and reopened['native']==after['native']
    summary={'passed':True,'runtime':'real frozen Wasm replay + SessionStore','initial_enemies':len(before['native']['enemies']),
      'final_enemies':len(after['native']['enemies']),'turn':after['view']['turn'],'receipts':receipts,'map_query_no_write':True,
      'retry_no_duplicate':True,'rejected_no_write':True,'handover_preserved':True,'elapsed_seconds':time.monotonic()-started}
    (a.output/'summary.json').write_text(json.dumps(summary,ensure_ascii=False,indent=2),encoding='utf8')
    print(json.dumps({k:v for k,v in summary.items()if k!='receipts'}))


if __name__=='__main__':main()
