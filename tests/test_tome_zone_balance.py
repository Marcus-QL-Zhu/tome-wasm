from copy import deepcopy
import unittest
from unittest.mock import patch
from tome_mvp.zone_balance import recommend_zone,zone_reference_level


def fixture():
    return {'model_id':'isolated','distance_weights':[1.9,.95],'maximum_calibrated_distance':2,
      'target_success_range':[.75,.90],'target_success':.825,'templates':{'forest':'old-forest'},'mapping':{
      'elasticity':.5,'enabled':True,'knots':[[.28,16],[2.54,24],[19.7,80]],'profiles':[
        {'id':'low','party':[{'level':10,'gear_score':15}]*3,'reference_level':16},
        {'id':'mid','party':[{'level':25,'gear_score':25}]*3,'reference_level':24},
        {'id':'high','party':[{'level':50,'gear_score':55}]*3,'reference_level':80}]}}


class ZoneBalanceTests(unittest.TestCase):
    def test_published_mapping_is_available_for_all_three_ecologies(self):
        party=[{'level':25,'gear_score':30},{'level':24,'gear_score':22},{'level':24,'gear_score':26}]
        values=[]
        for kind in ('forest','dungeon','cave','future-ecology'):
            level=zone_reference_level(party,kind,selection_key='isolated-area:1')
            self.assertIs(type(level),int)
            self.assertTrue(1<=level<=150)
            values.append(level)
        self.assertEqual(len(set(values)),1)

    def test_anchor_and_member_order_are_stable(self):
        model=fixture();p=model['mapping']['profiles'][1]['party']
        self.assertEqual(recommend_zone(p,model=model)['reference_level'],24)
        p=[{'level':50,'gear_score':55},{'level':24,'gear_score':25},{'level':10,'gear_score':15}]
        self.assertEqual(recommend_zone(p,model=model),recommend_zone(p[::-1],model=model))
        self.assertEqual(p[0]['level'],50)

    def test_equipment_changes_selection_and_bounds_remain_legal(self):
        model=fixture();weak=[{'level':25,'gear_score':10}]*3;strong=[{'level':25,'gear_score':40}]*3
        self.assertLess(recommend_zone(weak,model=model)['reference_level'],recommend_zone(strong,model=model)['reference_level'])
        for p in [[{'level':1,'gear_score':0}]*3,[{'level':50,'gear_score':200}]*3]:
            result=recommend_zone(p,model=model);self.assertTrue(1<=result['reference_level']<=150);self.assertTrue(result['warning'])

    def test_level_and_equipment_progression_are_monotone(self):
        model=fixture()
        levels=[recommend_zone([{'level':n,'gear_score':25}]*3,model=model)['reference_level']for n in range(1,51)]
        gear=[recommend_zone([{'level':25,'gear_score':n}]*3,model=model)['reference_level']for n in range(0,101)]
        self.assertEqual(levels,sorted(levels));self.assertEqual(gear,sorted(gear))

    def test_bad_data_and_disabled_mapping_fail_explicitly(self):
        model=fixture();p=[{'level':10,'gear_score':15}]*3
        for bad in [[],p[:2],[{'level':True,'gear_score':15}]*3,[{'level':10,'gear_score':-1}]*3]:
            with self.assertRaises(ValueError):recommend_zone(bad,model=model)
        self.assertEqual(recommend_zone(p,'cave',model=model)['reference_level'],recommend_zone(p,'forest',model=model)['reference_level'])
        self.assertFalse(recommend_zone(p,model=model)['validated'])
        model['mapping']['enabled']=False
        with patch('tome_mvp.zone_balance._model',return_value=model):
            with self.assertRaisesRegex(ValueError,'disabled'):zone_reference_level(p)

    def test_real_host_callback_uses_mapping(self):
        from dm_mvp.server_bindings import ServerBindings
        instance=ServerBindings.__new__(ServerBindings);p=[{'level':10,'gear_score':15}]*3
        with patch('tome_mvp.zone_balance._model',return_value=fixture()):self.assertEqual(instance.area_reference_level(p,'forest'),16)

    def test_host_binds_world_area_and_floor_to_stable_selection(self):
        from dm_mvp.server_bindings import ServerBindings
        instance=ServerBindings.__new__(ServerBindings);instance.config={'world_id':'test-world'}
        p=[{'level':10,'gear_score':15}]*3
        with patch('tome_mvp.zone_balance.zone_reference_level',return_value=16)as callback:
            self.assertEqual(instance.area_reference_level(p,'forest',area_id='area-1',floor=2),16)
        self.assertEqual(callback.call_args.kwargs,{'selection_key':'["test-world","area-1",2]'})

    def test_fractional_tiers_round_identically_across_area_keys(self):
        model=fixture();p=[{'level':10,'gear_score':15}]*3
        model['mapping']['knots']=[[.1,15.5],[1,15.5],[20,80]]
        values=[recommend_zone(p,model=model,selection_key='area:'+str(i))['reference_level']for i in range(100)]
        self.assertEqual(set(values),{recommend_zone(p,model=model)['reference_level']})
        self.assertEqual(values,[recommend_zone(p,model=model,selection_key='area:'+str(i))['reference_level']for i in range(100)])


if __name__=='__main__':unittest.main()
