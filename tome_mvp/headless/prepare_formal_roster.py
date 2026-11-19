"""Translate frozen public character data into a small native roster fixture."""
import json
from pathlib import Path

root = Path(__file__).resolve().parents[2]
base = root / 'artifacts/tome-formal-squad-20261111'
characters = json.loads((base / 'characters.json').read_text(encoding='utf-8'))
mapping = {}
for line in (base / 'talent-icon-map.txt').read_text(encoding='utf-8').splitlines():
    _, icon, values = line.split('\t')
    mapping[icon] = [item.split(':', 2) for item in values.split(',') if item]

def quote(value):
    return json.dumps(value, ensure_ascii=False)

lines = ['-- Generated from frozen public pages; this is not an imported save.', 'return {']
for char in characters:
    page = json.loads((base / 'sources' / f"character-{char['id']}.json").read_text(encoding='utf-8'))
    sex_rows = [r[1] for r in page['sections']['Character']['rows'] if len(r) >= 2 and r[0] == 'Sex']
    if len(sex_rows) != 1 or sex_rows[0] not in ('Male', 'Female'):
        raise ValueError(f"missing sex for {char['id']}")
    stats = char['primary_stats']
    attrs = ','.join(f'{key}={int(stats[name]["base"])}' for key, name in [
        ('str', 'Strength'), ('dex', 'Dexterity'), ('con', 'Constitution'),
        ('mag', 'Magic'), ('wil', 'Willpower'), ('cun', 'Cunning')])
    kind = 'Afflicted' if char['class'] == 'Cursed' else 'Warrior'
    race = 'Human' if char['race'] == 'Cornac' else char['race']
    lines.append('{id=%s,name=%s,sex=%s,race=%s,subrace=%s,class=%s,subclass=%s,level=%d,source_mode=%s,stats={%s},talents={' % (
        quote(char['id']), quote(char['title'].split(' the level ')[0]), quote(sex_rows[0]), quote(race), quote(char['race']),
        quote(kind), quote(char['class']), char['level'], quote(char['mode']), attrs))
    for skill in char['learned_skills']:
        icon = skill['icon_path'].split('/')[-1]
        candidates = [v for v in mapping[icon] if v[2] == skill['name_en']]
        if len(candidates) > 1:
            category = skill['category']
            suffix = ('technique/2hweapon-assault' if 'Two-handed assault' in category else
                      'technique/strength-of-the-berserker' if "Berserker's strength" in category else None)
            candidates = [v for v in candidates if v[1] == suffix]
        if len(candidates) != 1:
            raise ValueError(f"ambiguous talent {char['id']}: {skill['name_en']} {candidates}")
        lines.append('{id=%s,rank=%d,mastery=%s},' % (quote(candidates[0][0]), int(skill['rank'].split('/')[0]), skill['mastery']))
    lines.append('}},')
lines.append('}')
(root / 'tome_mvp/headless/formal_roster_data.lua').write_text('\n'.join(lines) + '\n', encoding='utf-8')
