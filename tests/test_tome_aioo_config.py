import unittest
from tome_mvp.service import validate_ai_config

class AIConfigValidationTests(unittest.TestCase):
    def test_valid_and_invalid_inputs(self):
        good={'stop_on_rare':True,'stop_enemy_count':0,'talent_weights':{'T_RUSH':0,'T_SHOOT':1.5}}
        self.assertEqual(validate_ai_config(good),good)
        for bad in [dict(good,stop_on_rare=1),dict(good,stop_enemy_count=True),dict(good,talent_weights={'../x':1}),dict(good,talent_weights={'T_RUSH':float('nan')}),dict(good,talent_weights={'T_RUSH':11}),dict(good,path='elsewhere')]:
            with self.subTest(bad=bad), self.assertRaises(ValueError): validate_ai_config(bad)
