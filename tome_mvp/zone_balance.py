"""One deterministic party-to-reference-level mapping for every ecology.

Only native current levels and worn material-tier sums are inputs. The older
special-encounter model supplies distance weights, not a Zone success rate.
"""
from functools import lru_cache
import json
import math
from pathlib import Path

CONFIG=Path(__file__).resolve().parents[1]/'config/tome_zone_balance.json'


def _party(value, allow_small=False):
    if not isinstance(value,list)or not (1 if allow_small else 3)<=len(value)<=3:raise ValueError('three party estimates required')
    rows=[]
    for actor in value:
        if not isinstance(actor,dict)or set(actor)!={'level','gear_score'}:raise ValueError('level and worn gear_score required')
        if type(actor['level'])is not int or not 1<=actor['level']<=50:raise ValueError('level must be 1..50')
        if type(actor['gear_score'])is not int or not 0<=actor['gear_score']<=200:raise ValueError('worn gear_score must be 0..200')
        rows.append(dict(actor))
    return sorted(rows,key=lambda x:(x['level'],x['gear_score']),reverse=True)


@lru_cache(maxsize=1)
def _model():
    return json.loads(CONFIG.read_text(encoding='utf8'))


def recommend_zone(party,kind='forest',*,model=None,selection_key=None,allow_small=False):
    party=_party(party,allow_small);model=model if model is not None else _model()
    if not isinstance(kind,str)or not kind:raise ValueError('Zone kind required')
    mapping=model['mapping']
    a,b=model['distance_weights']
    def power(rows):
        return sum((r['level']/25)**a*((r['gear_score']+1)/31)**b for r in rows)
    query_power=power(party)
    knots=mapping['knots'];outside=query_power<knots[0][0]or query_power>knots[-1][0]
    if query_power<=knots[0][0]:
        estimate=knots[0][1]*(query_power/knots[0][0])**mapping['elasticity']
    elif query_power>=knots[-1][0]:
        estimate=knots[-1][1]*(query_power/knots[-1][0])**mapping['elasticity']
    else:
        for (p0,r0),(p1,r1)in zip(knots,knots[1:]):
            if p0<=query_power<=p1:
                t=math.log(query_power/p0)/math.log(p1/p0)
                estimate=math.exp((1-t)*math.log(r0)+t*math.log(r1));break
    estimate=max(1,min(150,estimate))
    # Keep the optional key for existing area callbacks. It no longer changes
    # strength: the same party gets the same integer in every ecology/area.
    if selection_key is not None and (not isinstance(selection_key,str)or not selection_key):raise ValueError('invalid area key')
    level=math.floor(estimate+.5)
    warning='Unified strength estimate; ecology difficulty is preserved. No per-ecology success guarantee.'
    if outside:warning+=' Party strength is outside the reference anchors.'
    return {'reference_level':level,'expected_reference_level':estimate,'template':model.get('templates',{}).get(kind),'model_id':model['model_id'],
            'target_success_range':model['target_success_range'],'target_success':model['target_success'],
            'party_strength':query_power,'validated':False,'mapping_enabled':mapping.get('enabled',False),'warning':warning,
            'basis':'one shared strength curve; actual worn tier sums; ecology rules remain native'}


def zone_reference_level(party,kind='forest',*,selection_key=None):
    """Host callback. Ecology selects content, never a separate strength curve."""
    result=recommend_zone(party,kind,selection_key=selection_key,allow_small=True)
    if not result['mapping_enabled']:raise ValueError('Zone strength mapping is disabled')
    return result['reference_level']
