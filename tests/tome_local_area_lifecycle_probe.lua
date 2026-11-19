local area=require 'local_area'
local p=s.player
local source=game.level
local pet=assert(s.enemies[1])
pet.faction=p.faction;pet.summoner=p
game.party:addMember(pet,{type='ally',control='no',orders={},keep_between_levels=true})
local temporary=assert(s.enemies[2])
temporary.faction=p.faction;temporary.summoner=p
game.party:addMember(temporary,{type='ally',control='no',orders={},temporary_level=true})
local calls={leave=0,enter=0}
local zonecalls={leave=0,enter=0}
local oldleave=game.zone.on_leave
game.zone.on_leave=function(...)zonecalls.leave=zonecalls.leave+1;if oldleave then return oldleave(...) end end
local fire=p.fireTalentCheck
p.fireTalentCheck=function(self,name,phase,...)
 if name=='callbackOnChangeLevel' and calls[phase] then calls[phase]=calls[phase]+1 end
 return fire(self,name,phase,...)
end
p:setEffect(p.EFF_ZERO_GRAVITY,1,{})
area.bind(s,{area_id='review-a',floor_count=1})
local target={area_id='review-b',floor=1,config={map={kind='dungeon',size=64},zone={template='ruins-kor-pul',reference_level=20,floor_count=2}}}
game.player=pet;s.player=pet
local ok=pcall(area.transition,s,target)
assert(not ok and game.level==source and source:hasEntity(pet)==pet,'controlled auxiliary not rejected before mutation')
game.player=p;s.player=p
local turn=game.turn
area.transition(s,target)
assert(game.party:hasMember(pet) and game.level:hasEntity(pet)==pet and not source:hasEntity(pet),'auxiliary did not accompany party')
assert(not game.party:hasMember(temporary) and not game.level:hasEntity(temporary),'temporary member incorrectly followed')
assert(not p:hasEffect(p.EFF_ZERO_GRAVITY),'old zone effect retained')
assert(calls.leave==1 and calls.enter==1,'native change-level callbacks not executed')
assert(zonecalls.leave==1,'native zone leave not executed')
assert(game.turn==turn,'transition advanced time')
local prior_enter=game.zone.on_enter
game.zone.on_enter=function(...)zonecalls.enter=zonecalls.enter+1;if prior_enter then return prior_enter(...)end end
area.transition(s,{area_id='review-b',floor=2})
assert(game.level:hasEntity(pet)==pet and calls.leave==2 and calls.enter==2 and zonecalls.enter==1,'auxiliary or callback lost on next floor')
area.transition(s,{area_id='review-a',floor=1})
assert(game.level==source and source:hasEntity(pet)==pet and calls.leave==3 and calls.enter==3,'return lifecycle mismatch')
print('LOCAL_AREA_PROBE_OK lifecycle')
