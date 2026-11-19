-- Preserve only the original scalar-key serialization order of native Zone
-- prototype graphs. This weak side table never owns a game object.
local json=require 'json_validate'
local M={}
local witness=setmetatable({},{__mode='k'})
local byref=setmetatable({},{__mode='v'})
local function scalar(k)local t=type(k);return t=='string' or t=='boolean' or t=='number' and k==k and k~=math.huge and k~=-math.huge end
local capture={__newindex=function(t,k,v)
 local s=witness[t];if s and scalar(k)then s.keys[#s.keys+1]=k elseif s then witness[t]=nil end;rawset(t,k,v)
end}
local function same(t,keys)
 local seen,n={},0
 for _,k in ipairs(keys)do if not scalar(k) or seen[k] or rawget(t,k)==nil then return false end;seen[k]=true end
 for k in pairs(t)do if not seen[k]then return false end;n=n+1 end
 return n==#keys
end
function M.begin(ref,owner,t)
 if owner:sub(1,5)~='zone:' then return end
 assert(type(t)=='table' and not getmetatable(t),'invalid native order target')
 witness[t]={ref=ref,keys={}};byref[ref]=t;setmetatable(t,capture)
end
function M.finish(t,override)
 if rawequal(getmetatable(t),capture)then setmetatable(t,nil)end
 local s=witness[t];if not s then assert(not override,'invalid native order target');return end
 if override then assert(same(t,override),'invalid native source-order witness');s.keys=override end
end
function M.discard(t)witness[t]=nil end
function M.pairs(t)
 local s=witness[t];if not s or not same(t,s.keys)then return pairs(t)end
 local i=0;return function()i=i+1;local k=s.keys[i];if k~=nil then return k,rawget(t,k)end end
end
function M.export(owner,fragments)
 local out=json.object();if owner:sub(1,5)~='zone:' then return out end
 for ref in pairs(fragments)do
  local t=byref[ref];local s=t and witness[t]
  if s and same(t,s.keys)then
   local i,changed=0,false;for k in pairs(t)do i=i+1;if s.keys[i]~=k then changed=true;break end end
   if changed then local a=json.array();for n,k in ipairs(s.keys)do a[n]=k end;out[ref]=a end
  end
 end
 return out
end
return M
