-- Test-only instrumentation around the normal protocol, not a client method.
local input,output=protocol_read,protocol_write
local before
local function snapshot()
 local r=rng.state_get()
 local out={}
 for i,v in ipairs(r.words) do out[#out+1]=tostring(i)..':'..tostring(v) end
 for k,v in pairs(r) do if k~='words' then out[#out+1]=tostring(k)..':'..tostring(v) end end
 table.sort(out)
 local state={table.concat(out,';'),tostring(game.turn)}
 for _,a in ipairs(game.party.m_list) do
  local actor={tostring(a.uid),tostring(a.life),tostring(a.max_life),tostring(a.energy.value)}
  for _,d in ipairs(a.resources_def or {}) do
   actor[#actor+1]=d.short_name..':'..tostring(a[d.short_name])..':'..tostring(a[d.minname])..':'..tostring(a[d.maxname])
  end
  for id,cd in pairs(a.talents_cd or {}) do actor[#actor+1]='cd:'..tostring(id)..':'..tostring(cd) end
  for id,e in pairs(a.tmp or {}) do if type(e)=='table' then actor[#actor+1]='eff:'..tostring(id)..':'..tostring(e.dur) end end
  for id in pairs(a.sustain_talents or {}) do actor[#actor+1]='sustain:'..tostring(id) end
  table.sort(actor); state[#state+1]=table.concat(actor,';')
 end
 return table.concat(state,'|')
end
protocol_read=function()
 local line,too_long=input()
 if line and line:find('"method":"observe"',1,true) and game and game.party then before=snapshot() end
 return line,too_long
end
protocol_write=function(line)
 if before then assert(snapshot()==before,'observation changed RNG, turn, party resources, effects, cooldowns or sustains'); before=nil end
 return output(line)
end
dofile('/worker.lua')
