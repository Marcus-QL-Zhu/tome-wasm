-- Static installed-content inventory. A loaded definition is not a pass mark.
local M={}
function M.read()
 local json=require 'json_validate'
 local talents=json.array()
 local native=require 'native_actions'
 local policy=require 'content_policy'
 for id,t in pairs(require('engine.interface.ActorTalents').talents_def) do
  if type(id)=='string' then
   talents[#talents+1]=json.object({id=id,name=t.name or id,mode=t.mode or 'activated',policy_available=policy.allowed_talent(id),manual_adapter=native.target_kind(id) or json.null,
    requires_target=type(t.requires_target)=='function' and 'dynamic' or (t.requires_target and 'yes' or 'no'),
    target_definition=type(t.target),interaction_route=t.mode=='passive' and 'passive' or 'native_coroutine',verification='not_implied_by_catalog'})
  end
 end
 local class_births=json.array()
 local defs=require('engine.Birther').birth_descriptor_def
 for parent,d in pairs(defs.class or {})do
  if type(parent)=='string' then
   for child,choice in pairs(d.descriptor_choices and d.descriptor_choices.subclass or {})do
    if type(child)=='string' and child~='__ALL__' and choice~='disallow' and defs.subclass[child] then
     class_births[#class_births+1]=json.object({class=parent,subclass=child,choice=tostring(choice),policy_available=policy.allowed_class(child)})
    end
   end
  end
 end
 table.sort(class_births,function(a,b)return a.class==b.class and a.subclass<b.subclass or a.class<b.class end)
 local race_births=json.array()
 for parent,d in pairs(defs.race or {})do
  if type(parent)=='string' then
   for child,choice in pairs(d.descriptor_choices and d.descriptor_choices.subrace or {})do
    if type(child)=='string' and child~='__ALL__' and choice~='disallow' and defs.subrace[child] then
     race_births[#race_births+1]=json.object({race=parent,subrace=child,choice=tostring(choice)})
    end
   end
  end
 end
 table.sort(race_births,function(a,b)return a.race==b.race and a.subrace<b.subrace or a.race<b.race end)
 table.sort(talents,function(a,b)return a.id<b.id end)
 local births=json.object({})
 for kind,entries in pairs(require('engine.Birther').birth_descriptor_def) do
  if type(kind)=='string' and type(entries)=='table' then
  local names=json.array()
  for name in pairs(entries) do if type(name)=='string' then names[#names+1]=name end end
  table.sort(names);births[kind]=names
  end
 end
 local sources=json.array();for _,name in ipairs(fs.list('/data/general/npcs')) do if name:match('%.lua$') then sources[#sources+1]=name:gsub('%.lua$','') end end;table.sort(sources)
 return json.object({npc_sources=sources,class_births=class_births,race_births=race_births,all_units_verified=false,known_rule_callback_limits=json.array({'periodic_visual_rule_callbacks_unverified'}),one_shot_rule_events=true,format='tome-native-catalog-v1',talents=talents,birth_descriptors=births,scope='installed_base_content',all_talents_verified=false})
end
M.read=require('localization').wrap(M.read)
return M
