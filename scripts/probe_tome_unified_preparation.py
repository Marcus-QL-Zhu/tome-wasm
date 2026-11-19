"""Exercise the real frozen validator against a synthetic partition candidate."""
import argparse
import json
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from tome_mvp.wasm.session_store import SessionStore, wire


def run(kernel, candidate_path, output):
    candidate = json.loads(candidate_path.read_text(encoding='utf8'))
    scope = {k: candidate['manifest'][k] for k in ('build', 'world_id', 'campaign_id')}
    database = output.with_suffix('.sqlite')
    if database.exists():
        raise FileExistsError(database)
    store = SessionStore(database, kernel / 'public', native_checkpoints=True, native_partitions=True)
    with store.connect() as db:
        db.execute('INSERT INTO battles VALUES(?,?,?,?,?,?)', ('proof', 0, 'active', wire({'format': 'fixture-old', 'build': scope['build']}), wire({}), wire({})))
    store._commit_partition_candidate('proof', 0, 'initial', scope, candidate)
    before = store.get('proof')
    catalog = store.inspect_scene('proof', {'catalog_only': True, 'source': 'orc'})
    assert catalog['enemy_catalog'] and store.get('proof') == before
    entries = [{'person_id': 'probe-person', 'person_name': 'Probe Person', 'count': 1, 'difficulty': 'hard', 'same_room': True}]
    receipt = store.prepare_enemies('proof', 1, 'reencounter', entries, base_reference_level=40)
    actor = receipt['enemies'][0]
    assert actor['actor_id'] == candidate['native']['world_people']['probe-person']['actor_uid']
    assert actor['level'] == candidate['native']['world_people']['probe-person']['level']
    assert store.prepare_enemies('proof', 1, 'reencounter', entries, base_reference_level=40) == receipt
    saved = store.get('proof')
    with store.connect() as db:
        receipt_count = db.execute('SELECT COUNT(*) FROM receipts').fetchone()[0]
    bad = [{'enemy_id': actor['enemy_id'], 'count': 1}, {'enemy_id': 'orc:DOES_NOT_EXIST', 'count': 1}]
    try:
        store.prepare_enemies('proof', saved['version'], 'atomic-failure', bad, base_reference_level=10)
    except ValueError:
        pass
    else:
        raise AssertionError('invalid second enemy was accepted')
    assert store.get('proof') == saved
    with store.connect() as db:
        assert db.execute('SELECT COUNT(*) FROM receipts').fetchone()[0] == receipt_count
    report = {'passed': True, 'runtime': 'real frozen Wasm and SQLite', 'production_access': False,
              'catalog_read_only': True, 'cold_person_restored': actor, 'retry_deduplicated': True,
              'second_enemy_failure_rolled_back_batch': True, 'version': saved['version']}
    output.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding='utf8')
    print(json.dumps(report, ensure_ascii=False))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--kernel', type=Path, required=True)
    parser.add_argument('--candidate', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    run(args.kernel, args.candidate, args.output)
