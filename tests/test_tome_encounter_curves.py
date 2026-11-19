from tome_mvp.encounter_curves import interpolate, nearest_reference, matchup_probability


def test_piecewise_curve_preserves_native_level_order_and_bounds():
    points=[[10,.95],[25,.75],[40,.1],[50,.05]]
    values=[interpolate(points,l) for l in range(1,60)]
    assert all(a>=b for a,b in zip(values,values[1:]))
    assert interpolate(points,10)==.95 and interpolate(points,25)==.75
    assert abs(interpolate(points,31)-.49)<1e-10


def test_more_enemy_hp_cannot_be_scored_as_easier_from_sampling_noise():
    ref={'curves':{'3:1':{'points':[[10,.8],[50,.2]]},'3:2':{'points':[[10,.9],[50,.3]]}}}
    for level in range(10,51):assert matchup_probability(ref,3,level,2)<=matchup_probability(ref,3,level,1)


def test_reference_uses_existing_individual_numeric_inputs_only():
    low=[{'level':10,'gear_score':15}]*3
    mixed=[{'level':50,'gear_score':55},{'level':24,'gear_score':22},{'level':12,'gear_score':14}]
    ref,distance=nearest_reference(mixed,{'distance_weights':[1.9,.95],'profiles':[{'id':'low','party':low},{'id':'mixed','party':mixed}]})
    assert ref['id']=='mixed' and distance==0
