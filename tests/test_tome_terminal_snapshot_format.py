"""Exercise the real checkpoint projection before terminal reporting."""
import pytest

from dm_mvp.wasm_battle import WasmBattleBridge
from tome_mvp.wasm.session_store import SessionStore, wire


@pytest.mark.parametrize('format,kind',[
    ('tome-replay-save-v1','reconstructible_replay'),
    ('tome-native-session-v1','native_checkpoint'),
    ('tome-partition-session-v1','native_checkpoint'),
])
def test_terminal_summary_uses_public_format_without_exposing_snapshot(tmp_path,format,kind):
    store=SessionStore(tmp_path/'battle.sqlite',tmp_path)
    archive={'format':format,'events':[],'audit':[]}
    with store.connect() as db:
        db.execute('INSERT INTO battles VALUES(?,?,?,?,?,?)',
                   ('battle',1,'active',wire(archive),wire({'generation':1,'status':'victory','turn':40}),wire({'private':'native objects'})))
    bridge=WasmBattleBridge.__new__(WasmBattleBridge)
    bridge.authorize_access=None
    bridge._store=lambda **scope:store
    result=bridge.finish(campaign_id='c',world_id='w',owner_id='o',id='run',battle_id='battle')
    assert result['character_snapshot_kind']==kind
    assert result['archive_format']==format
    assert result['scene_id']=='1.0'
    assert 'archive' not in result and 'native' not in result
