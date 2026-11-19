-- Native translations at presentation boundaries. Simulation stays en_US.
local M={}
local active=false
local ready=false
local enabled=true
local unpack=unpack
local damage_names={}
local damage_labels={}
local extra={['Mercenary Rescue']='救援队友',['mercenary rescue']='队友救援',['Prodigies']='奥义',['prodigies']='奥义',
 ['PAI_STATE_EXPLORE']='自动探索中',['PAI_STATE_FIGHT']='自动战斗中',['PAI_STATE_REST']='自动休息中',
 ['AIoo stopped']='自动控制已停止',['AIoo stopped by user']='自动控制已暂停',
 stamina='体力值',mana='法力值',positive='正能量',negative='负能量',equilibrium='失衡',paradox='悖论',hate='仇恨',vim='活力',psi='灵能',feedback='反馈',steam='蒸汽',souls='灵魂'}
local function packed(...)return {n=select('#',...),...}end
function M.initialize(language)
 if ready then return end
 ready=true;enabled=language~='en_US'
 local I=require 'engine.I18N'
 local Font=require 'engine.FontPackage';local prior=Font.forceId
 Font.forceId=function()end -- Browser fonts, not desktop font packages.
 local ok,err=pcall(function()
  I:loadLocale('/data/locales/engine/zh_hans.lua')
  I:loadLocale('/data/locales/zh_hans.lua')
 end)
 Font.forceId=prior
 if not ok then error(err)end
 -- These native locale flags alter generation rather than presentation.
 local locale_data=packed(I:getLocalesData())
 for _,flag in ipairs({'ego_always_prefix','ego_always_suffix','randart_name_rules'}) do locale_data[10].zh_hans[flag]=nil end
 -- The bundled translation predates the current wording of this native talent.
 I:t('zh_hans',[[Hits the target with your weapon, doing %d%% damage. If the attack hits, the target's armour and saves are reduced by %d for %d turns.
		Also if the target is protected by any temporary magical or psionic damage absorbing shields there is %d%% chance to shatter a random shield.
		Armor reduction chance increases with your Physical Power.]],[[用武器攻击目标，造成 %d%% 伤害。命中后，目标的护甲和豁免降低 %d，持续 %d 回合。
		如果目标受到临时魔法或灵能伤害吸收护盾保护，有 %d%% 的概率击碎其中一个随机护盾。
		护甲降低效果受物理强度加成。]],'tformat')
 I:setLocale('en_US')
 I:setLocale('zh_hans')
  for _,def in pairs(require('engine.DamageType').dam_def) do
   local name=def.name;local translated=_t(name,'damage type')
   if type(name)=='string' and translated~=name then damage_labels[name]=translated;damage_names[#damage_names+1]={name=name,pattern='%f[%a]'..name:gsub('([^%w])','%%%1')..'%f[^%a]',text=translated}end
  end
 I:setLocale('en_US')
 table.sort(damage_names,function(a,b)return #a.name>#b.name end)
 for _,Class in ipairs({require 'mod.class.Actor',require 'mod.class.NPC',require 'mod.class.Player',require 'mod.class.PartyMember'}) do
  local get_name=Class.getName
  Class.getName=function(self,...)local name=get_name(self,...);return active and M.text(name,'entity name') or name end
 end
 local raw_format=string.format
 local formatting=false
 string.format=function(s,...)
  if not active or formatting then return raw_format(s,...)end
  -- Some native descriptions use :format rather than :tformat. Apply the
  -- native argument-order rules only while rendering, never during actions.
  formatting=true
  local args=packed(...)
  for i=1,args.n do if type(args[i])=='string' then args[i]=M.text(args[i])end end
  local result=packed(pcall(default_tformat,s,'tformat',unpack(args,1,args.n)))
  formatting=false
  if not result[1] then error(result[2],0)end
  return unpack(result,2,result.n)
 end
 local native_format=string.tformat
 string.tformat=function(s,...)
  if not active then return native_format(s,...)end
  local args=packed(...)
  for i=1,args.n do if type(args[i])=='string' then args[i]=M.text(args[i])end end
  local prior=formatting;formatting=true
  local result=packed(pcall(native_format,s,unpack(args,1,args.n)))
  formatting=prior
  if not result[1] then error(result[2],0)end
  return unpack(result,2,result.n)
 end
 local noun_sub=string.noun_sub
 string.noun_sub=function(s,from,to)
  -- Effect messages otherwise lose their translation key before game.log.
 if from=='#Target#' or from=='#target#' or from=='#Source#' or from=='#source#' then
   return M.with(function()return noun_sub(M.text(s),from,M.text(to,'entity name'))end)
  end
  return noun_sub(s,from,to)
 end
 local to_tstring=string.toTString
 string.toTString=function(s,...)
  return to_tstring(active and M.text(s) or s,...)
 end
 local add=tstring.add
 tstring.add=function(self,...)
  if not active then return add(self,...)end
  local args=packed(...)
  for i=1,args.n do if type(args[i])=='string' then args[i]=M.text(args[i])end end
  return add(self,unpack(args,1,args.n))
 end
 local Object=require 'mod.class.Object';local native=Object.getName
 Object.getName=function(self,options)
  if not active or options and options.raw_name then return native(self,options)end
  local name=M.object_name(self)
  if name==self.name then return M.object_categories(native(self,options),self)end
  -- A read-only proxy avoids changing the saved object's actual name.
  local proxy=setmetatable({name=name},{__index=self})
  return M.object_categories(native(proxy,options),self)
 end
end
local game_installed=false
function M.install_game(Game)
 if game_installed then return end;game_installed=true
 local message=Game.logMessage;local damage=Game.delayedLogDamage
 Game.logMessage=function(...)return M.with(message,...)end
 Game.delayedLogDamage=function(self,src,target,dam,desc,crit)
  return M.with(function()return damage(self,src,target,dam,M.damage_description(desc),crit)end)
 end
end
function M.with(fn,...)
 if not enabled or active then return fn(...)end
 local I=require 'engine.I18N';active=true;I:setLocale('zh_hans')
 local result=packed(pcall(fn,...))
 I:setLocale('en_US');active=false
 if not result[1] then error(result[2],0)end
 return unpack(result,2,result.n)
end
function M.text(s,tag)
 if type(s)~='string' then return s end
 if not enabled then return s end
 local uid=s:match('#UID:(%d+):[^#]*#')
 local object=uid and __uids and __uids[tonumber(uid)]
 if object and object.__CLASSNAME=='mod.class.Object' then
  local plain=s:gsub('#[%w_:]+#',''):gsub('#{[%w_]+}#','')
  local name=tostring(object:getName{do_color=false,no_count=true})
  if name~=plain then return s:gsub(plain:gsub('([^%w])','%%%1'),function()return name end,1)end
 end
 local plain=s:gsub('#[%w_:]+#',''):gsub('#{[%w_]+}#','')
 if plain~=s then
  local value=M.text(plain,tag)
  if value~=plain then return s:gsub(plain:gsub('([^%w])','%%%1'),function()return value end,1)end
 end
 local translated=_t(s,tag)
 if translated~=s then return translated end
 local lower=s:gsub('^%u',string.lower)
 if lower~=s then translated=_t(lower,tag);if translated~=lower then return translated end end
 local person,kind=s:match('^(.-) the (.+)$')
 if person then local name=_t(kind,'entity name');if name~=kind then return person..'（'..name..'）'end end
 local effect,source=s:match('^(.-) from (.+)$')
 if effect then local name=_t(effect);if name~=effect then return name..'（来源：'..M.text(source,'entity name')..'）'end end
 local base,proper=s:match("^(.-) '(.*)'$")
 if base then local name=_t(base,'entity name');if name~=base then return name..'「'..proper..'」'end end
 local prefix,stat,number=s:match('^(%-?%s*)(%a[%a ]-)%s+([%+%-]?%d+%.?%d*)$')
 if stat then local value=_t(stat,'stat name');if value==stat then value=_t(stat:gsub('^%u',string.lower),'stat name')end;if value~=stat and value~=stat:gsub('^%u',string.lower) then return prefix..value..' '..number end end
 return extra[s] or extra[lower] or s
end
function M.damage_description(text)
 if not active or type(text)~='string' then return text end
 local color,number,name,close=text:match('^(#[^#]+#)([%-%d%.]+) (.-)(#LAST#)$')
 if color and damage_labels[name] then return color..number..' '..damage_labels[name]..close end
 for _,entry in ipairs(damage_names)do text=text:gsub(entry.pattern,entry.text)end
 return text:gsub('rampage shugs off','狂暴抵消')
end
function M.category(id)
 local a,b=tostring(id):match('^([^/]+)/(.+)$')
 if not a then return M.text(id)end
 local def=require('engine.interface.ActorTalents').talents_types_def[id]
 return M.text(a,'talent category')..' / '..M.text(def and def.name or b,'talent type')
end
function M.object_categories(text,o)
 local defs=require('engine.interface.ActorTalents').talents_types_def
 for id in pairs(o.wielder and o.wielder.talents_types_mastery or {}) do
  local def=defs[id]
  if def then local raw=_t(id:gsub('/.*',''),'talent category'):capitalize().._t(' / ')..def.name:capitalize();text=text:gsub(raw:gsub('([^%w])','%%%1'),function()return M.category(id)end)end
 end
 return text:gsub('%(([%a ]+)%)',function(label)return '('..M.text(label)..')'end)
end
function M.description(text,o)
 if not active then return text end
 text=M.object_categories(text,o)
 for _,label in ipairs({'a mind power','a nature gift'}) do text=text:gsub(label,function()return M.text(label)end)end
 return text
end
function M.object_name(o)
 local original=o.__original
 if not original or not o.ego_list then return M.text(o.name,'entity name')end
 local raw,display=original.name,M.text(original.name,'entity name')
 for _,entry in ipairs(o.ego_list) do
  local ego=entry[1]
  if ego and not entry[3] then
   local value=ego.display_string or ego.name or ''
   local zh=M.text(value,'entity name')
   if ego.prefix or ego.display_prefix then raw=value..raw else raw=raw..value end
   -- The native Chinese convention puts ego labels before the base name.
   display=zh..display
  end
 end
 -- Preserve story renames and unknown custom naming schemes.
 if raw~=o.name then
  if o.randart or o.rare then
   local renamed,count=o.name:gsub(raw:gsub('([^%w])','%%%1'),function()return display end,1)
   if count>0 then return renamed:gsub('^(.-) the ','%1的',1)end
  end
  return M.text(o.name,'entity name')
 end
 return display
end
local fields={name=true,title=true,label=true,prompt=true,description=true,desc=true,race=true,class=true,requirement=true,current=true,next=true}
function M.display(value)
 if type(value)~='table' then return value end
 for key,item in pairs(value) do
  if type(item)=='table' and key~='descriptor' and key~='actors' then M.display(item)
  elseif fields[key] and type(item)=='string' then value[key]=M.text(item)end
 end
 return value
end
function M.wrap(fn)
 return function(...)return M.with(function(...)local result=packed(fn(...));for i=1,result.n do M.display(result[i])end;return unpack(result,1,result.n)end,...)end
end
function M.format(fmt,...)
 return M.with(function(...)
  local args=packed(...)
  if active then
   fmt=extra[fmt] or fmt
   for i=1,args.n do if type(args[i])=='string' then args[i]=M.text(args[i])end end
  end
  return (fmt or ''):tformat(unpack(args,1,args.n)):toString()
 end,...)
end
return M
