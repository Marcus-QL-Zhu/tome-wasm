local M={}
function M.sources(config,defaults)
 local roster={}
 for i,spec in ipairs(config.party) do
  local source=spec.birth and {id='injected-'..i,name='Adventurer '..i,level=1,stats={},talents={},source_mode='encounter',sex=spec.birth.sex,race=spec.birth.race,subrace=spec.birth.subrace,class=spec.birth.class,subclass=spec.birth.subclass}
  for _,entry in ipairs(defaults) do if entry.id==spec.template then source=table.clone(entry,true) end end
  assert(source,'unknown source template')
  source.name=spec.name or source.name;source.level=spec.level or source.level
  for k,v in pairs(spec.stats or {}) do source.stats[k]=v end
  -- Explicit talents add or replace native ranks. Inherited talents remain.
  for _,t in ipairs(spec.talents or {}) do
   local found=false
   for _,old in ipairs(source.talents) do if old.id==t.id then old.rank=t.rank;old.mastery=t.mastery or old.mastery;found=true end end
   if not found then source.talents[#source.talents+1]={id=t.id,rank=t.rank,mastery=t.mastery or 1} end
  end
  roster[i]=source
 end
 return roster
end
function M.equip(actor,spec,zone,level)
 local out={}
 for _,item in ipairs(spec.equipment or {}) do
  local prototype
  for _,candidate in ipairs(zone.object_list) do if candidate.name==item.name or candidate.define_as==item.name then prototype=candidate;break end end
  assert(prototype,'unknown native object '..item.name)
  local o=assert(zone:finishEntity(level,'object',prototype,-1000),'native object construction failed')
  local inv=assert(actor['INVEN_'..item.slot],'unknown inventory slot')
  assert(actor:getInven(inv),'slot absent from native body')
  local can,why=actor:canWearObject(o,actor:getInven(inv).name)
  assert(can,'native wear denied: '..tostring(why))
  local worn=actor:wearObject(o,true,false,inv)
  assert(worn,'native wear failed')
  if type(worn)=='table' then assert(actor:addObject(actor.INVEN_INVEN,worn),'displaced equipment not preserved') end
  o:identify(true);out[#out+1]={name=item.name,slot=item.slot}
 end
 return out
end
return M
