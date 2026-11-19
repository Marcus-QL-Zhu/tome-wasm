"""Typed engineering encounter inputs. These do not authorize campaign changes."""
from copy import deepcopy
import math
import re

# Exported from the bundled 1.7.6 native content policy for early HTTP validation.
_DENIED_TALENTS = frozenset('''
T_AMBUSCADE T_ANOMALY_BLAZING_FIRE T_ANOMALY_BLINK T_ANOMALY_CALCIFY T_ANOMALY_CALL
T_ANOMALY_DEUS_EX T_ANOMALY_DIG T_ANOMALY_DISPLACEMENT_SHIELD T_ANOMALY_DUST_STORM T_ANOMALY_ENTOMB
T_ANOMALY_ENTROPY T_ANOMALY_EVIL_TWIN T_ANOMALY_FLAWED_DESIGN T_ANOMALY_GRAVITY_PULL
T_ANOMALY_GRAVITY_WELL T_ANOMALY_HASTE T_ANOMALY_INTERSECTING_THREADS T_ANOMALY_INVIGORATE
T_ANOMALY_MASS_DIG T_ANOMALY_METEOR T_ANOMALY_PROBABILITY_TRAVEL T_ANOMALY_QUAKE T_ANOMALY_REARRANGE
T_ANOMALY_SLOW T_ANOMALY_SPACETIME_TEAR T_ANOMALY_SPHERE_OF_DESTRUCTION T_ANOMALY_STOP
T_ANOMALY_SUMMON_TIME_ELEMENTAL T_ANOMALY_SUMMON_TOWNSFOLK T_ANOMALY_SWAP T_ANOMALY_TELEPORT
T_ANOMALY_TEMPORAL_BUBBLE T_ANOMALY_TEMPORAL_CLONE T_ANOMALY_TEMPORAL_SHIELD
T_ANOMALY_TEMPORAL_STORM T_ANOMALY_TORNADO T_ANOMALY_WORMHOLE T_ARROW_ECHOES T_ARROW_STITCHING
T_ARROW_THREADING T_ASHES_TO_ASHES T_ATTENUATE T_BANISH T_BLADE_SHEAR T_BLADE_WARD T_BLENDED_THREADS
T_BLINK_BLADE T_BODY_REVERSION T_BRAID_LIFELINES T_BREACH T_CARBON_SPIKES T_CEASE_TO_EXIST
T_CELERITY T_CHRONO_TIME_SHIELD T_COMMAND_BLINK T_COMMAND_BREATHE T_CONTINGENCY T_DAMAGE_SMEARING
T_DESTABILIZE T_DIMENSIONAL_ANCHOR T_DIMENSIONAL_SHIFT T_DIMENSIONAL_STEP T_DISINTEGRATION
T_DISPLACE_DAMAGE T_DREDGE_FRENZY T_DUST_TO_DUST T_ECHOES_FROM_THE_PAST T_EMPOWER
T_ENERGY_ABSORPTION T_ENERGY_DECOMPOSITION T_ENTROPIC_FIELD T_ENTROPY T_EXTENSION T_FADE_FROM_TIME
T_FATEWEAVER T_FOLD_FATE T_FOLD_GRAVITY T_FOLD_WARP T_FORESIGHT T_GATHER_THE_THREADS T_GRAVITY_LOCUS
T_GRAVITY_SPIKE T_GRAVITY_WELL T_GUARDIAN_UNITY T_HASTE T_INDUCE_ANOMALY T_INVIGORATE
T_TEMPORAL_RIPPLES T_MECHARACHNID_PILOTING T_MATERIALIZE_BARRIER T_MATRIX T_MATTER_WEAVING T_MOMENT_OF_PRESCIENCE T_OVER_MIND T_PARADOX_CLONE
T_PERFECT_AIM T_PHASE_PULSE T_PHASE_SHIFT T_PHASE_SHOT T_PRECOGNITION T_PROJECTION T_QUANTUM_FEED
T_QUANTUM_SPIKE T_QUICKEN T_QUICK_SHOT T_REALITY_SMEARING T_REDUX T_REPULSION_BLAST
T_REPULSION_FIELD T_RETHREAD T_REVISIONIST_HISTORY T_REVISIONIST_HISTORY_BACK T_SEAL_FATE
T_SEE_THE_THREADS T_SEVER_LIFELINE T_SINGULARITY_ARROW T_SLOW T_SPACETIME_MASTERY
T_SPACETIME_STABILITY T_SPACETIME_TUNING T_SPATIAL_TETHER T_SPEED_SAP T_SPIN_FATE T_STATIC_HISTORY
T_STOP T_STRENGTH_OF_PURPOSE T_SWAP T_TEMPORAL_BOLT T_TEMPORAL_CLONE T_TEMPORAL_FUGUE
T_TEMPORAL_FUGUE_OLD T_TEMPORAL_HOUNDS T_TEMPORAL_REPRIEVE T_TEMPORAL_VIGOUR T_TEMPORAL_WAKE
T_THREAD_THE_NEEDLE T_THREAD_WALK T_TIME_DILATION T_TIME_SKIP T_TIME_STOP T_TURN_BACK_THE_CLOCK
T_TWIST_FATE T_UNERRING_SHOT T_VIGILANCE T_WARDEN_S_CALL T_WARDEN_S_FOCUS T_WARP_BLADE T_WARP_MINES
T_WARP_MINE_AWAY T_WARP_MINE_TOWARD T_WEAPON_FOLDING T_WEAPON_MANIFOLD T_WEBS_OF_FATE T_WORMHOLE
'''.split())


def validate_map(value):
    if not isinstance(value, dict) or set(value) - {'kind', 'size', 'room_count'} or 'kind' not in value:
        raise ValueError('invalid map fields')
    if value['kind'] not in ('rooms', 'dungeon', 'forest', 'cave', 'town', 'tavern'):
        raise ValueError('unsupported map kind')
    size = value.get('size', 20)
    if type(size) is not int or not 10 <= size <= 64:
        raise ValueError('square map size must be an integer in 10..64')
    rooms = value.get('room_count', 4)
    if type(rooms) is not int or not 4 <= rooms <= 8:
        raise ValueError('room count must be an integer in 4..8')
    if 'room_count' in value and value['kind'] not in ('rooms', 'dungeon'):
        raise ValueError('room_count applies only to rooms/dungeon')
    return deepcopy(value)


def validate_battle_request(*, seed, enemies, map, area=None):
    """Check scene input before reserving an asynchronous preparation job."""
    if type(seed) is not int:
        raise ValueError('seed must be an integer in 0..2147483647')
    request={'format':'tome-encounter-v1','seed':seed,
             'party':[{'template':x} for x in ('184917','159442','425367')],
             'enemies':enemies,'map':map}
    if area is not None:
        if not isinstance(area,dict) or enemies or not isinstance(map,dict) or set(map)!={'kind','size'}:
            raise ValueError('persistent areas require an empty enemy list and a native 64x64 Zone')
        template={'forest':'old-forest','dungeon':'ruins-kor-pul','cave':'trollmire'}.get(map.get('kind'))
        if template is None:
            raise ValueError('unsupported persistent area ecology')
        floor=area.get('floor');count=area.get('floor_count')
        if type(floor) is not int or not 1<=floor<=20:
            raise ValueError('area floor must be an integer in 1..20')
        if count is not None and (type(count) is not int or not floor<=count<=20):
            raise ValueError('area floor_count must be an integer between floor and 20')
        if map['kind']=='forest' and (floor!=1 or count not in (None,1)):
            raise ValueError('forest has one floor')
        request['zone']={'template':template,'reference_level':1}
    validate_encounter(request)


def validate_encounter(value, *, allow_bootstrap=False):
    def obj(v, allowed, required=()):
        if not isinstance(v, dict) or set(v) - set(allowed) or set(required) - set(v):
            raise ValueError(f"invalid fields; allowed={allowed}, required={required}")

    def number(v, lo, hi, integer=False):
        if isinstance(v, bool) or not isinstance(v, (int, float)) or not math.isfinite(v) or not lo <= v <= hi or (integer and int(v) != v):
            raise ValueError(f"expected {'integer' if integer else 'number'} in {lo}..{hi}")

    def text(v, limit=128):
        if not isinstance(v, str) or not 0 < len(v) <= limit or any(ord(c) < 32 for c in v):
            raise ValueError("invalid text")

    def talent(t):
        obj(t, ('id', 'rank', 'mastery'), ('id', 'rank'))
        if not isinstance(t['id'], str) or not re.fullmatch(r'T_[A-Z0-9_:]+', t['id']):
            raise ValueError('invalid native talent id')
        if t['id'] in _DENIED_TALENTS:
            raise ValueError(f"content policy rejects talent: {t['id']}")
        number(t['rank'], 1, 5, True)
        number(t.get('mastery', 1), .1, 3)

    obj(value, ('format', 'seed', 'party', 'enemies', 'map', 'purpose', 'zone'), ('format', 'seed', 'party', 'enemies', 'map'))
    bootstrap=value.get('purpose')=='party_bootstrap'
    if 'purpose' in value and (not bootstrap or not allow_bootstrap):raise ValueError('bootstrap requires trusted host')
    if 'zone' in value:
        validate_map(value['map'])
        obj(value['zone'], ('template', 'reference_level'), ('template', 'reference_level'))
        if bootstrap: raise ValueError('bootstrap cannot generate a Zone')
        if value['zone']['template'] not in ('old-forest','ruins-kor-pul','trollmire'):
            raise ValueError('unsupported native Zone ecology')
        number(value['zone']['reference_level'],1,150,True)
        if value['map'].get('kind') not in ('forest','dungeon','cave') or value['map'].get('size')!=64:
            raise ValueError('native Zone calibration requires a 64x64 forest, dungeon or cave')
    if value['format'] != 'tome-encounter-v1':
        raise ValueError('unsupported encounter format')
    number(value['seed'], 0, 2147483647, True)
    if not isinstance(value['party'], list) or len(value['party']) != 3:
        raise ValueError('this release requires exactly three party members')
    for a in value['party']:
        obj(a, ('template', 'birth', 'name', 'level', 'stats', 'talents', 'equipment', 'portrait', 'campaign_identity'))
        if 'campaign_identity' in a:
            obj(a['campaign_identity'], ('person_id', 'origin'), ('person_id', 'origin'))
            text(a['campaign_identity']['person_id'])
            text(a['campaign_identity']['origin'])
        if ('template' in a) == ('birth' in a): raise ValueError('choose template or native birth descriptors')
        if 'template' in a and a['template'] not in ('184917', '159442', '425367'):
            raise ValueError('unknown source template')
        if 'birth' in a:
            obj(a['birth'], ('sex','race','subrace','class','subclass'), ('sex','race','subrace','class','subclass'))
            for v in a['birth'].values(): text(v)
            if a['birth']['subclass'] in ('Paradox Mage','Temporal Warden'): raise ValueError('content policy rejects class: '+ a['birth']['subclass'])
        if 'name' in a: text(a['name'])
        if 'level' in a: number(a['level'], 1, 50, True)
        if 'stats' in a:
            obj(a['stats'], ('str', 'dex', 'con', 'mag', 'wil', 'cun'))
            for n in a['stats'].values(): number(n, 1, 1000)
        if 'talents' in a:
            if not isinstance(a['talents'], list) or len(a['talents']) > 100: raise ValueError('invalid talents')
            for t in a['talents']: talent(t)
            if len({t['id'] for t in a['talents']}) != len(a['talents']): raise ValueError('duplicate talent')
        if 'portrait' in a:
            p = a['portrait']
            if not isinstance(p, str) or not re.fullmatch(r'data/gfx/(?:[\w.-]+/)*[\w.-]+\.png', p) or '..' in p:
                raise ValueError('portrait must be an admitted native asset path')
        if 'equipment' in a:
            if not isinstance(a['equipment'], list) or len(a['equipment']) > 20: raise ValueError('invalid equipment')
            for e in a['equipment']:
                obj(e, ('name', 'slot'), ('name', 'slot'))
                text(e['name'])
                if e['slot'] not in ('MAINHAND','OFFHAND','BODY','HEAD','HANDS','FEET','LITE','QUIVER','TOOL','FINGER','NECK','BELT','CLOAK'):
                    raise ValueError('invalid equipment slot')
    identities = [a['campaign_identity']['person_id'] for a in value['party'] if 'campaign_identity' in a]
    if identities and (len(identities) != 3 or len(set(identities)) != 3):
        raise ValueError('campaign identities must be complete and unique')
    enemies = value['enemies']
    if not isinstance(enemies, list) or not (len(enemies)==0 if bootstrap or 'zone' in value else 1 <= len(enemies) <= 10): raise ValueError('expected 1..10 enemies; bootstrap and native Zone require an empty explicit list')
    for e in enemies:
        obj(e, ('kind','source', 'prototype', 'class', 'level', 'hp_multiplier', 'talents'), ('prototype', 'level'))
        if 'source' in e and (not isinstance(e['source'], str) or not re.fullmatch(r'[a-z0-9_-]+',e['source'])):
            raise ValueError('invalid native npc source')
        if e.get('kind','rare') not in ('rare','native'): raise ValueError('unknown native spawn kind')
        if e.get('kind')=='native' and 'class' in e: raise ValueError('class applies to Rare creation only')
        text(e['prototype'])
        if 'class' in e:
            text(e['class'])
            if e['class'] in ('Paradox Mage','Temporal Warden'): raise ValueError('content policy rejects class: '+ e['class'])
        number(e['level'], 1, 50, True)
        number(e.get('hp_multiplier', 2), .1, 10)
        if 'talents' in e:
            if not isinstance(e['talents'], list) or len(e['talents']) > 100: raise ValueError('invalid talents')
            for t in e['talents']: talent(t)
    validate_map(value['map'])
    return deepcopy(value)
