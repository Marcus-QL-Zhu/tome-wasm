"""Native Zone input boundary; actual ecology and outcome use real-Wasm trials."""
from copy import deepcopy
import unittest
from tome_mvp.encounter import validate_encounter


class NativeZoneContractTests(unittest.TestCase):
    def setUp(self):
        self.value=dict(format='tome-encounter-v1',seed=41,
                        party=[{'template':x}for x in ('184917','159442','425367')],
                        enemies=[],map={'kind':'forest','size':64},
                        zone={'template':'old-forest','reference_level':35})

    def test_zone_accepts_empty_explicit_list_without_changing_party_levels(self):
        before=deepcopy(self.value)
        self.assertEqual(validate_encounter(self.value),before)
        self.assertEqual(self.value,before)
        del self.value['zone']
        with self.assertRaises(ValueError):validate_encounter(self.value)

    def test_guardian_and_difficulty_cannot_override_fixed_policy(self):
        for key,value in [('guardian','WRATHROOT'),('difficulty','Normal')]:
            candidate=deepcopy(self.value);candidate['zone'][key]=value
            with self.assertRaises(ValueError):validate_encounter(candidate)

    def test_rejects_silent_ignored_story_enemy_and_invalid_reference(self):
        self.value['enemies']=[{'prototype':'orc warrior','level':10}]
        with self.assertRaises(ValueError):validate_encounter(self.value)
        self.value['enemies']=[]
        for level in (0,151,True,float('nan')):
            self.value['zone']['reference_level']=level
            with self.assertRaises(ValueError):validate_encounter(self.value)


if __name__=='__main__':unittest.main()
