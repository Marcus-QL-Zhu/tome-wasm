import unittest
from pathlib import Path
import struct
import tempfile
from copy import deepcopy
from tome_mvp.encounter import validate_encounter
from tome_mvp.encounter_launch import stage_portraits


class EncounterContractTests(unittest.TestCase):
    def setUp(self):
        self.value = {'format':'tome-encounter-v1','seed':23,
                      'party':[{'template':x} for x in ('184917','159442','425367')],
                      'enemies':[{'source':'orc','prototype':'orc warrior','level':18}],
                      'map':{'kind':'rooms','room_count':4}}

    def test_template_and_native_birth_are_distinct(self):
        out = validate_encounter(self.value)
        out['party'][0]['name'] = 'other'
        self.assertNotIn('name', self.value['party'][0])
        self.value['party'][0]={'birth':{'sex':'Male','race':'Human','subrace':'Cornac','class':'Warrior','subclass':'Bulwark'},'stats':{'str':40},'equipment':[{'name':'steel shield','slot':'OFFHAND'}]}
        validate_encounter(self.value)
        self.value['party'][0]['template']='184917'
        with self.assertRaises(ValueError): validate_encounter(self.value)

    def test_rejects_unknown_fields_paths_and_nonfinite_numbers(self):
        for change in (
            lambda x:x.update(lua='os.execute()'),
            lambda x:x['enemies'][0].update(source='../orc'),
            lambda x:x['party'][0].update(portrait='data/gfx/../secret.png'),
            lambda x:x['enemies'][0].update(hp_multiplier=float('nan')),
            lambda x:x.update(seed=True),
            lambda x:x['party'][0].update(talents=[{'id':'T_RUSH','rank':True}]),
        ):
            candidate=deepcopy(self.value);change(candidate)
            with self.assertRaises(ValueError): validate_encounter(candidate)

    def test_does_not_claim_unimplemented_map_or_party_shapes(self):
        for key,value in [('party',[]),('map',{'kind':'unknown-map'}),('enemies',[])]:
            candidate=deepcopy(self.value);candidate[key]=value
            with self.assertRaises(ValueError): validate_encounter(candidate)

    def test_portrait_alias_and_size_are_bounded(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp);source=root/'source.png'
            # This test covers header admission. Browser decoding is a separate check.
            source.write_bytes(b'\x89PNG\r\n\x1a\n'+b'\x00\x00\x00\x0dIHDR'+struct.pack('>II',64,64))
            assets=stage_portraits([f'commander={source}'],root/'out')
            self.assertIn('data/gfx/encounter/commander.png',assets)
            self.assertEqual((root/'out/data/gfx/encounter/commander.png').read_bytes(),source.read_bytes())
            with self.assertRaises(ValueError): stage_portraits([f'../bad={source}'],root/'bad')
            with self.assertRaises(ValueError): stage_portraits([f'a={source}',f'a={source}'],root/'dupe')
            source.write_bytes(b'not a PNG')
            with self.assertRaises(ValueError): stage_portraits([f'a={source}'],root/'invalid')

if __name__ == '__main__': unittest.main()
