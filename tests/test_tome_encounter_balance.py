import unittest
import json
from pathlib import Path
from tempfile import TemporaryDirectory
from tome_mvp.encounter import validate_map, validate_encounter
from tome_mvp.encounter_balance import select_enemies
from tome_mvp.encounter_launch import package_frozen


class EncounterSelectionTests(unittest.TestCase):
    def test_weaker_party_gets_weaker_foes_and_target_changes_choice(self):
        low = [{'level':10,'gear_score':15}]*3
        mid = [{'level':25,'gear_score':28}]*3
        a = select_enemies(low,3,.75)
        b = select_enemies(mid,3,.75)
        self.assertLess(a['enemies'][0]['level'], b['enemies'][0]['level'])
        harder = select_enemies(low,3,.4)
        self.assertGreater(harder['enemies'][0]['level'], a['enemies'][0]['level'])
        for result in (a,b,harder):
            validate_encounter({'format':'tome-encounter-v1','seed':13,
                                'party':[{'template':x} for x in ('184917','159442','425367')],
                                'enemies':result['enemies'],'map':result['map']})
            # Integer levels do not guarantee an arbitrary probability gap.
            # Validate the receipt and relative difficulty here; target quality
            # is measured by the separate frozen native-battle evaluation.
            self.assertTrue(result['target_in_candidate_range'])
            self.assertAlmostEqual(result['absolute_probability_gap'],abs(result['predicted_win_probability']-result['target_win_probability']))
            self.assertFalse(result['target_probability_calibrated'])

    def test_reports_unreachable_target_without_inventing_levels(self):
        result = select_enemies([{'level':50,'gear_score':60}]*3,1,.5)
        self.assertFalse(result['target_in_candidate_range'])
        self.assertTrue(result['warning'])
        self.assertEqual(result['enemies'][0]['level'],50)
        self.assertFalse(result['native_construction_verified'])

    def test_input_and_map_boundaries(self):
        for kind in ('tavern','dungeon','forest','cave','town','rooms'):
            for size in (10,37,64): validate_map({'kind':kind,'size':size})
        for value in ({'kind':'forest','size':65},{'kind':'cave','size':9},
                      {'kind':'town','size':True},{'kind':'sea'},
                      {'kind':'forest','room_count':4}):
            with self.assertRaises(ValueError):validate_map(value)
        for count in (0,6,True):
            with self.assertRaises(ValueError):select_enemies([{'level':10,'gear_score':15}]*3,count,.75)
        for target in (float('nan'),0,1,True):
            with self.assertRaises(ValueError):select_enemies([{'level':10,'gear_score':15}]*3,3,target)

    def test_old_kernel_cannot_silently_ignore_requested_map(self):
        with TemporaryDirectory(dir='artifacts') as tmp:
            base=Path(tmp)/'old';base.mkdir()
            (base/'identity.json').write_text(json.dumps({'build_id':'old','inputs':{}}),encoding='utf8')
            with self.assertRaisesRegex(ValueError,'does not support the requested map'):
                package_frozen(base,Path(tmp)/'out',{'map':{'kind':'forest','size':64}})


if __name__ == '__main__':unittest.main()
