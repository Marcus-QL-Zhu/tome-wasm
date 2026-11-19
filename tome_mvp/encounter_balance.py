"""Read-only encounter selection. Native construction remains authoritative."""
import argparse
import json
import math
from pathlib import Path

from .encounter import validate_map
from .encounter_curves import nearest_reference, matchup_probability

CONFIG = Path(__file__).resolve().parents[1] / 'config/tome_encounter_balance.json'


def number(value, lo, hi, *, integer=False):
    if type(value) not in (int, float) or not math.isfinite(value) or not lo <= value <= hi or (integer and int(value) != value):
        raise ValueError(f'expected number in {lo}..{hi}')


def predict(party, enemies, hp_multiplier=1, *, model=None):
    model = model or json.loads(CONFIG.read_text(encoding='utf8'))
    c = model['coefficients']
    def total(actors):
        return sum(100 * (a['level']/25)**c['level_exponent'] *
                   ((a['gear_score']+1)/31)**c['gear_exponent'] for a in actors)
    z = c['side_bias'] + c['temperature'] * math.log(total(party)/total(enemies)) - c['hp_logit_penalty'] * math.log(hp_multiplier)
    return 1/(1+math.exp(-max(-700, min(700, z))))


def select_enemies(party, enemy_count, target_win_probability, *, map=None, model=None):
    if not isinstance(party, list) or len(party) != 3:
        raise ValueError('three party estimates required')
    for actor in party:
        if not isinstance(actor, dict) or set(actor) != {'level', 'gear_score'}:
            raise ValueError('party estimates require level and gear_score only')
        number(actor['level'], 1, 50, integer=True)
        number(actor['gear_score'], 0, 200, integer=True)
    number(enemy_count, 1, 5, integer=True)
    number(target_win_probability, .01, .99)
    scene_map = validate_map(map or {'kind': 'dungeon', 'size': 20})
    model = model or json.loads(CONFIG.read_text(encoding='utf8'))
    calibration=model.get('selection_calibration')
    reference,distance=nearest_reference(party,calibration) if calibration else (None,None)
    roles = ('Bulwark', 'Berserker', 'Archmage', 'Bulwark', 'Berserker')[:int(enemy_count)]
    anchors = model['enemy_gear_anchors']
    def gear(level, index):
        # Interpolate the observed native loadouts. No gear is fabricated or equipped here.
        levels = sorted(int(k) for k in anchors)
        lo = max((k for k in levels if k <= level), default=levels[0])
        hi = min((k for k in levels if k >= level), default=levels[-1])
        a, b = anchors[str(lo)][index], anchors[str(hi)][index]
        return a if lo == hi else a + (b-a)*(level-lo)/(hi-lo)
    candidates = []
    # The admitted orc-warrior prototype has a native minimum level of 10.
    for level in range(10, 51):
        estimates = [{'level': level, 'gear_score': gear(level, i)} for i in range(int(enemy_count))]
        for hp in (1, 2):
            probability = matchup_probability(reference,int(enemy_count),level,hp) if reference else predict(party, estimates, hp, model=model)
            candidates.append((abs(probability-target_win_probability), hp, level, probability, estimates))
    probabilities = [c[3] for c in candidates]
    reachable = min(probabilities) <= target_win_probability <= max(probabilities)
    pool=candidates
    if reference:
        primary=[c for c in candidates if c[1]==1]
        # HP x1 is the native baseline. Do not switch HP merely to shave a
        # tiny interpolation error inside its supported difficulty range.
        if min(c[3] for c in primary)<=target_win_probability<=max(c[3] for c in primary):pool=primary
    if target_win_probability<min(probabilities):
        selected=min(pool,key=lambda c:(c[0],-c[2],-c[1]))
    else:selected=min(pool,key=lambda c:c[:3])
    error, hp, level, probability, estimates = selected
    return {'status': 'selected', 'model_id': calibration['model_id'] if calibration else model['model_id'], 'party_estimates': party,
            'enemy_count': int(enemy_count), 'target_win_probability': target_win_probability,
            'predicted_win_probability': probability, 'absolute_probability_gap': error,
            'target_in_candidate_range': reachable,
            'available_probability_range': [min(probabilities), max(probabilities)],
            'enemies': [{'source': 'orc', 'prototype': 'orc warrior', 'kind': 'rare',
                         'class': role, 'level': level, 'hp_multiplier': hp} for role in roles],
            'enemy_estimates': estimates, 'map': scene_map,
            'native_construction_verified': False, 'target_probability_calibrated': False,
            'basis': ('Monotone observed win-rate curves for the nearest numeric party reference. Native equipment rolls are part of the sampled outcome distribution; no extra input variables.' if reference else 'Interpolated mean worn-tier sums from native Rare samples. Final native rolls can differ. Open-room, full-state model; terrain is not a fitted feature.'),
            'reference': {'id':reference['id'],'distance':distance,'party':reference['party'],
                          'curve_support':reference['curves'][f'{int(enemy_count)}:{hp}']['support']} if reference else None,
            'warning': None if reachable else 'Target outside the current data-supported native level 10..50, HP x1/x2 probability range; returned closest configuration.'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--input', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    value = json.loads(args.input.read_text(encoding='utf8'))
    result = select_enemies(**value)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open('x', encoding='utf8') as out:
        json.dump(result, out, ensure_ascii=False, indent=2)
    print(json.dumps(result, ensure_ascii=False))


if __name__ == '__main__':
    main()
