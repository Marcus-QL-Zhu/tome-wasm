"""Derive static NPC metadata from a verified, isolated native save boundary."""
import argparse
import hashlib
import json
from pathlib import Path
import sys
import tempfile

sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from dm_mvp.server_bindings import _enemy_catalog
from dm_mvp.wasm_battle import _verify_frozen_run
from tome_mvp.wasm.session_store import SessionStore, loadout_boundary


def export(run,kernel,output):
    run=run.resolve(strict=True);kernel=kernel.resolve(strict=True)
    _verify_frozen_run(run,kernel)
    if output.exists():raise ValueError('catalog output already exists')
    store=SessionStore(run/'session-data/battles.sqlite',run/'mvp/public',
                       native_checkpoints=True,native_partitions=True)
    with store.connect() as db:
        ids=db.execute('SELECT id FROM battles').fetchall()
    if len(ids)!=1:raise ValueError('one isolated native camp required')
    bid=ids[0][0];saved=store.get(bid)
    if saved['archive'].get('format')!='tome-partition-session-v1' or not loadout_boundary(saved):
        raise ValueError('export from an isolated native save at a loadout boundary')
    sources=store.inspect_scene(bid,{'catalog_only':True})['enemy_sources']
    operations=[{'operation':'scene_query','query':{'catalog_only':True,'source':source}} for source in sources]
    with store.lock,store.connect() as db:
        db.execute('BEGIN')
        result=store._partition_validate_tx(db,bid,saved['version'],saved['archive'],operations,{'kind':'loadout'})
    catalogs={source:[{key:row[key] for key in ('enemy_id','name','rank')} for row in reply['enemy_catalog']]
              for source,reply in zip(sources,result['results'],strict=True)}
    build=json.loads((kernel/'identity.json').read_text(encoding='utf8'))['build_id']
    asset={'format':'tome-native-enemy-catalog-v1','base_build_id':build,
           'enemy_sources':sorted(sources),'enemy_catalogs':catalogs}
    raw=(json.dumps(asset,ensure_ascii=False,sort_keys=True,separators=(',',':'))+'\n').encode('utf8')
    digest=hashlib.sha256(raw).hexdigest()
    with tempfile.TemporaryDirectory() as work:
        candidate=Path(work)/'catalog.json';candidate.write_bytes(raw)
        _enemy_catalog({'enemy_catalog_file':str(candidate),'enemy_catalog_sha256':digest,'frozen_kernel':str(kernel)})
    if store.get(bid)!=saved:raise ValueError('native camp changed during export')
    _verify_frozen_run(run,kernel)
    with output.open('xb') as file:file.write(raw)
    return {'path':str(output),'sha256':digest,'base_build_id':build,'bytes':len(raw),
            'sources':len(sources),'enemies':sum(map(len,catalogs.values())),'native_unchanged':True}


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--run',type=Path,required=True,help='isolated native run at a saved loadout boundary')
    parser.add_argument('--kernel',type=Path,required=True)
    parser.add_argument('--output',type=Path,required=True)
    args=parser.parse_args()
    print(json.dumps(export(args.run,args.kernel,args.output)))
