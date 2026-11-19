-- Source-based reconstruction using native entity prototypes and wear rules.
local M={}
local function base_name(s)
 local img=s.image
 local names={
  ['object/hboots_iron.png']='pair of iron boots', ['object/helm_iron.png']='iron helm',
  ['object/cap_rough.png']='rough leather cap', ['object/hgloves_iron.png']='iron gauntlets',
  ['object/gloves_rough.png']='rough leather gloves', ['object/cloak_linen.png']='linen cloak',
  ['object/ring_copper.png']='copper ring', ['object/ring_steel.png']='steel ring',
  ['object/amulet_copper.png']='copper amulet', ['object/axe_steel.png']='steel waraxe',
  ['object/2hsword_iron.png']='iron greatsword', ['object/shield_steel.png']='steel shield',
  ['object/plate_steel.png']='steel plate armour', ['object/plate_iron.png']='iron plate armour',
  ['object/mail_steel.png']='steel mail armour', ['object/lite_brass.png']='brass lantern',
  ['object/torque_iron.png']='iron torque',
 }
 return names[img]
end
function M.equip(actor,source_id,zone,level)
 local list=require('mod.class.Object'):loadList({'/data/general/objects/objects.lua','/data/general/objects/boss-artifacts-maj-eyal.lua'})
 local items=assert(require('formal_item_data')[tostring(source_id)],'unknown source')
 local output={}
 local destination={['On feet']='FEET',['Light source']='LITE',['On head']='HEAD',['On hands']='HANDS',['Tool']='TOOL',['On fingers']='FINGER',['Around neck']='NECK',['In main hand']='MAINHAND',['In off hand']='OFFHAND',['Around waist']='BELT',['Cloak']='CLOAK',['Main armor']='BODY'}
 local slot_counts={}
 for _,s in ipairs(items) do
  local wanted=s.fixed or assert(base_name(s),'unmapped source '..s.source_name)
  local p
  for _,candidate in ipairs(list) do if candidate.name==wanted and candidate.type==s.type and candidate.subtype==s.subtype then p=candidate break end end
  assert(p,'missing native prototype '..wanted)
  local chosen_addon
  if p.addons and s.source_name:find('of psionic shield',1,true) then
   local available=zone:getEgosList(level,'object',p.addons,p.__CLASSNAME) or {}
   for _,addon in ipairs(available) do if addon.name==' of psionic shield' then chosen_addon=addon break end end
   assert(chosen_addon,'missing psionic shield addon')
  end
  local base=p
  if chosen_addon then base=p:clone(); base.addons=nil end
  local o=assert(zone:finishEntity(level,'object',base,-1000))
  if chosen_addon then zone:applyEgo(o,chosen_addon,'object'); o:resolve(); o:resolve(nil,true) end
  local applied={}
  if not s.fixed and p.egos then
   local ego_list=zone:getEgosList(level,'object',p.egos,p.__CLASSNAME) or {}
   local picked={}
   for _,ego in ipairs(ego_list) do
    local token=ego.name and ego.name:gsub('%s*%b()',''):gsub('^%s+',''):gsub('%s+$','')
    local kind=ego.prefix and 'prefix' or ego.suffix and 'suffix'
    if token and token~='' and kind and not picked[kind] and s.source_name:lower():find(token:lower(),1,true) then
     local filter=game.state:egoFilter(zone,level,'object',kind,o,nil,applied,{})
     if (not filter.special or filter.special(ego)) and (not ego.level_range or ego.level_range[1]<=zone.base_level+level.level-1) then
      zone:applyEgo(o,ego,'object'); applied[#applied+1]=ego; picked[kind]=true
     end
    end
   end
   if #applied>0 then o:resolve(); o:resolve(nil,true) end
  end
  o:identify(true)
  o.formal_source_name=s.source_name
  local inv=assert(actor['INVEN_'..assert(destination[s.slot])])
  local index=(slot_counts[inv] or 0)+1; slot_counts[inv]=index
  local can,why=actor:canWearObject(o,actor:getInven(inv).name)
  local ok=can and actor:wearObject(o,true,false,inv,index)
  if type(ok)=='table' then
   local added=actor:addObject(actor.INVEN_INVEN,ok)
   assert(added,'failed to preserve displaced starting equipment')
  end
  local found_inven,found_slot
  for inven_id,inven in pairs(actor.inven) do if type(inven)=='table' then for slot,owned in ipairs(inven) do if owned==o then found_inven,found_slot=inven_id,slot end end end end
  assert(ok and found_inven and found_slot,'native wear rejected for '..s.source_name..': '..tostring(why))
  local difference=s.fixed and 'Native fixed unique; source curse and charge history may differ.' or 'Native same base and material, with matched source affixes when available; original rolls, random artifact and curse are not recovered.'
  output[#output+1]={slot=s.slot,source_name=s.source_name,object=o,uid=o.uid,actual_name=o:getName{do_color=false,no_count=true},worn=not not ok,inven=found_inven,inven_slot=found_slot,difference=difference,reason=why,matched_egos=#applied}
 end
 return output
end
return M



