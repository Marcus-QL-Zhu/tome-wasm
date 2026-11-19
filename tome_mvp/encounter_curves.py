"""Small monotone matchup regressions using the existing numeric inputs only."""
from bisect import bisect_right
import math


def nearest_reference(party, calibration):
    # Preserve individual levels/equipment instead of collapsing the team to
    # one additive score. Distance weights reuse the original fitted exponents.
    a,b=calibration['distance_weights']
    def distance(profile):
        return sum((a*math.log(x['level']/y['level']))**2 +
                   (b*math.log((x['gear_score']+1)/(y['gear_score']+1)))**2
                   for x,y in zip(party,profile['party']))
    result=min(calibration['profiles'],key=lambda p:(distance(p),p['id']))
    return result,math.sqrt(distance(result))


def interpolate(points, level):
    levels=[p[0] for p in points]
    i=bisect_right(levels,level)
    if i==0:return points[0][1]
    if i==len(points):return points[-1][1]
    x0,y0=points[i-1];x1,y1=points[i]
    return y0+(y1-y0)*(level-x0)/(x1-x0)


def matchup_probability(reference, enemy_count, enemy_level, hp_multiplier):
    key=f'{enemy_count}:{hp_multiplier}'
    if key not in reference['curves']:raise ValueError('unsupported native matchup curve')
    probability=interpolate(reference['curves'][key]['points'],enemy_level)
    if hp_multiplier==2:
        probability=min(probability,interpolate(reference['curves'][f'{enemy_count}:1']['points'],enemy_level))
    return probability
