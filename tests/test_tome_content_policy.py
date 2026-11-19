from copy import deepcopy
import pytest
from tome_mvp.encounter import validate_encounter

BASE = {'format':'tome-encounter-v1','seed':23,
        'party':[{'template':x} for x in ('184917','159442','425367')],
        'enemies':[{'source':'orc','prototype':'orc warrior','level':18}],
        'map':{'kind':'rooms'}}

@pytest.mark.parametrize('tid', ['T_REVISIONIST_HISTORY', 'T_REVISIONIST_HISTORY_BACK',
    'T_SEE_THE_THREADS', 'T_CEASE_TO_EXIST', 'T_PARADOX_CLONE', 'T_TEMPORAL_REPRIEVE','T_SLOW','T_TEMPORAL_FUGUE',
    'T_PROJECTION','T_OVER_MIND','T_AMBUSCADE','T_MECHARACHNID_PILOTING','T_TEMPORAL_RIPPLES'])
@pytest.mark.parametrize('side', ['party','enemies'])
def test_denied_explicit_talents(tid, side):
    value=deepcopy(BASE)
    value[side][0]['talents']=[{'id':tid, 'rank':1}]
    with pytest.raises(ValueError, match='content policy'):
        validate_encounter(value)

@pytest.mark.parametrize('side', ['party','enemies'])
@pytest.mark.parametrize('career',['Temporal Warden','Paradox Mage'])
def test_denied_subclass(side,career):
    value=deepcopy(BASE)
    if side=='party':
        value['party'][0]={'birth':{'sex':'Male','race':'Human','subrace':'Cornac',
                                 'class':'Chronomancer','subclass':career}}
    else:
        value['enemies'][0]['class']=career
    with pytest.raises(ValueError, match='content policy'):
        validate_encounter(value)

def test_ordinary_summons_and_thought_forms_remain_available():
    value=deepcopy(BASE)
    value['enemies'][0]['talents']=[{'id':'T_WAR_HOUND','rank':1}, {'id':'T_THOUGHT_FORMS','rank':1}]
    assert validate_encounter(value)==value
