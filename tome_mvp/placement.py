"""Host placement contract, shared by active edits and interrupted-battle replay."""
import re


def validate_spawn(value):
    allowed={'operation','operation_id','enemy_id','placement','x','y','person_id','person_name','person_birth','reference_level','source_area','source_floor'}
    if not isinstance(value,dict)or set(value)-allowed or not {'operation','operation_id','placement'}<=set(value):
        raise ValueError('invalid spawn fields')
    if value['operation']!='spawn_enemy':raise ValueError('invalid spawn operation')
    if not isinstance(value['operation_id'],str)or not 1<=len(value['operation_id'])<=100:raise ValueError('invalid placement identity')
    enemy=value.get('enemy_id')
    if enemy is None and 'person_id' not in value:raise ValueError('enemy type or world person required')
    if enemy is not None and (not isinstance(enemy,str)or len(enemy)>200 or not re.fullmatch(r'[a-z0-9_-]{1,64}:[^\x00-\x1f]{1,128}',enemy)):raise ValueError('invalid native enemy identity')
    for key in ('person_id','person_name','source_area'):
        if key in value and (not isinstance(value[key],str) or not value[key].strip() or len(value[key])>256):raise ValueError('invalid world person binding')
    if 'person_name' in value and 'person_id' not in value:raise ValueError('unbound person name')
    if 'person_birth' in value:
        birth=value['person_birth']
        if ('person_id' not in value or not isinstance(birth,dict) or
                set(birth)!={'race','subrace','class','subclass','sex'} or
                not all(isinstance(x,str) and 1<=len(x)<=48 for x in birth.values())):
            raise ValueError('invalid native person birth')
    if ('source_area' in value)!=('source_floor' in value):raise ValueError('incomplete source area')
    if 'source_floor' in value and (type(value['source_floor'])is not int or not 1<=value['source_floor']<=20 or 'person_id'not in value):raise ValueError('invalid person source floor')
    if 'reference_level' in value and (type(value['reference_level'])is not int or not 1<=value['reference_level']<=150):raise ValueError('invalid native reference level')
    if value['placement']not in ('exact','same_room','other_room'):raise ValueError('invalid placement mode')
    if value['placement']=='exact':
        if not {'x','y'}<=set(value)or any(type(value[k])is not int or not 0<=value[k]<64 for k in ('x','y')):raise ValueError('invalid coordinates')
    elif 'x'in value or 'y'in value:raise ValueError('quick placement does not accept coordinates')
    return dict(value)


def validate_scene_query(value):
    if not isinstance(value,dict)or set(value)-{'include_tiles','source','catalog_only'}:raise ValueError('invalid map query')
    if 'include_tiles'in value and type(value['include_tiles'])is not bool:raise ValueError('invalid map detail')
    if 'catalog_only'in value and type(value['catalog_only'])is not bool:raise ValueError('invalid catalog query')
    if 'source'in value and (not isinstance(value['source'],str)or not re.fullmatch(r'[a-z0-9_-]{1,64}',value['source'])):raise ValueError('invalid NPC source')
    return dict(value)
