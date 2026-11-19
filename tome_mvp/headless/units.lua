-- Discover real actors without adding summons to the mission objective list.
local M={}
function M.party(state)
 local result,seen={},{}
 for _,list in ipairs({state.allies,state.game.party and state.game.party.m_list or {}})do
  for _,a in ipairs(list)do
   if not seen[a] and (not state._plane_origin or state.game.level:hasEntity(a)) then seen[a]=true;result[#result+1]=a end
  end
 end
 table.sort(result,function(a,b)return a.uid<b.uid end)
 return result
end
function M.refresh(state)
 local actors,hostiles,others={},{},{}
 local party={};for _,a in ipairs(state.allies) do party[a]=true end
 for _,a in pairs(state.game.level.entities) do
  if not a.dead and a.x and a.y and a.getTalentFromId and a.reactionToward and state.map(a.x,a.y,state.Map.ACTOR)==a then
   actors[#actors+1]=a
   if not party[a] then
    if state.player:reactionToward(a)<0 then hostiles[#hostiles+1]=a else others[#others+1]=a end
   end
  end
 end
 local function order(a,b)return a.uid<b.uid end
 table.sort(actors,order);table.sort(hostiles,order);table.sort(others,order)
 state.observed_actors=actors;state.combatants=hostiles;state.auxiliaries=others
end
return M
