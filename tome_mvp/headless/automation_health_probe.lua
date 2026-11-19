dofile('/probe.lua')
local h=require('automation_health').new({is_down=function(a) return a.down end})
local a={uid=1,life=39,max_life=100}
local foe={uid=2}; local s={allies={a},enemies={foe},visible={[2]=true}}
assert(h.check(s) and h.alert()[1].percent==40); h.publish(); h.acknowledge()
a.life=38.9; assert(not h.check(s),'minor ongoing damage must not re-alert')
a.life=19; assert(h.check(s) and h.alert()[1].percent==20,'new 20 percent threshold must alert'); h.publish(); h.acknowledge()
a.life=80; assert(not h.check(s)); a.life=54; assert(h.check(s) and h.alert()[1].kind=='damage' and h.alert()[1].loss==26,'new large hit must alert'); h.publish(); h.acknowledge()
a.life=45; assert(not h.check(s)); a.life=39; assert(h.check(s) and h.alert()[1].percent==40,'recrossing must alert')
-- Publishing a batch does not publish a subsequently changed batch.
h.reset(); local b={uid=3,life=10,max_life=100}; a.life=10; s.allies={a,b}
assert(h.check(s)); assert(not h.acknowledge(),'unpublished batch must reject')
h.publish(); a.life=80; h.manual(s)
assert(not h.acknowledge(),'changed batch must be published again')
h.publish(); assert(h.acknowledge(),'published batch must be accepted')
print('PASS_AUTOMATION_HEALTH_EPISODES')
