-- Source-observed inscription values; native talents perform every effect.
local M={}
local specs={
 ['184917']={{'REGENERATION',{cooldown=10,dur=5,heal=100}},{'WILD',{cooldown=14,dur=4,power=14,what={physical=true}}},{'HEALING',{cooldown=13,heal=132,use_stat='str',use_stat_mod=2}}},
 ['159442']={{'REGENERATION',{cooldown=16,dur=5,heal=104,use_stat='mag',use_stat_mod=3.4}},{'WILD',{cooldown=14,dur=4,power=14,what={physical=true}}},{'HEALING',{cooldown=10,heal=64,use_stat='cun',use_stat_mod=2}},{'MOVEMENT',{cooldown=9,speed=502,use_stat='con',use_stat_mod=3}}},
 ['425367']={{'REGENERATION',{cooldown=10,dur=5,heal=100}},{'HEALING',{cooldown=10,heal=93,use_stat='wil',use_stat_mod=2}},{'PRISMATIC',{cooldown=18,dur=6,wards={ACID=3,PHYSICAL=4,LIGHTNING=3,COLD=3}}},{'BLINK',{cooldown=16,range=4,power=14,use_stat='wil',use_stat_mod=0.04}}},
}
function M.install(actor,source_id,zone,level)
 local entries=assert(specs[tostring(source_id)],'unknown source')
 -- A fourth observed inscription proves that a category point was spent.
 actor.max_inscriptions=math.max(actor.max_inscriptions,#entries)
 actor.inscriptions_slots_added=math.max(actor.inscriptions_slots_added or 0,#entries-3)
 local result={}
 for i,entry in ipairs(entries) do
  local kind, d=entry[1],table.clone(entry[2],true)
  local prefix=(kind=='PRISMATIC' or kind=='BLINK') and 'RUNE:_' or 'INFUSION:_'
  -- The source gives effective values, not base rolls; infer base at the
  -- actor's current stats and retain the native scaling coefficient.
  if d.use_stat then
   local inc=actor:getStat(d.use_stat)*d.use_stat_mod
   if kind=='MOVEMENT' then d.speed=d.speed-inc
   elseif kind=='BLINK' then d.range=d.range-inc; d.power=d.power-inc*3
   else d.heal=d.heal-inc end
  end
  assert(actor:setInscription(i,prefix..kind,d,false,false),'inscription rejected')
  result[#result+1]={slot=i,talent=actor.inscriptions[i],data=d,difference='Effective values reconstructed from public tooltip; hidden base roll and original slot history unavailable.'}
 end
 return result
end
return M

