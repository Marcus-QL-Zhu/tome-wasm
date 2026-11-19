-- Keep native Party permissions, class conversion and automatic return rules.
local M={}
local depth=0
function M.in_transition()return depth>0 end
function M.is_core(state,actor)
 for _,member in ipairs(state.allies)do if actor==member then return true end end
 return false
end
function M.allowed(state,actor)
 if not actor or actor==state.player or require('rescue').is_down(actor) then return false end
 if state._plane_origin and not state.game.level:hasEntity(actor) then return false end
 -- Existing saves can return from a secondary body to the leader.
 if actor~=state.allies[1] or M.is_core(state,state.player) then return false end
 return state.game.party:canControl(actor,false) and true or false
end
function M.targets(state)
 local result={}
 for _,actor in ipairs(state.game.party.m_list)do if M.allowed(state,actor)then result[#result+1]=actor end end
 table.sort(result,function(a,b)return a.uid<b.uid end)
 return result
end
function M.bind(state,before,after)
 local party=state.game.party;local original=party.setPlayer
 assert(not rawget(party,'__headless_control_bound'),'control listener already bound')
 party.__headless_control_bound=true
 party.setPlayer=function(self,actor,bypass)
  if type(actor)=='number' then actor=self.m_list[actor] end
  -- Covers native chat choices and deferred callbacks as well as skill actions.
  if actor and actor~=state.game.player and not M.is_core(state,actor) then return nil,'secondary_body_control_disabled' end
  local previous=state.game.player
  local finish=actor~=previous and before(previous,actor)
  depth=depth+1
  local result,reason=original(self,actor,bypass)
  depth=depth-1
  if finish then finish(result and state.game.player~=previous) end
  if result and state.game.player~=previous then
   local current=state.game.player
   assert(self:hasMember(current),'native control changed outside the party')
   state.player=current
   state.control_base_done=false
   state.control_serial=(state.control_serial or 0)+1
   state.control_change={serial=state.control_serial,previous=previous.uid,current=current.uid,turn=state.game.turn}
   after(previous,current)
  end
  return result,reason
 end
 -- Native setPlayer can pause before the new body's Player.act has run.
 -- Track that body-specific phase instead of reusing the old body's flag.
 local Player=require 'mod.class.Player';local act=Player.act
 Player.act=function(self,...)
  local function pack(...)return {n=select('#',...),...}end
  local result=pack(act(self,...))
  if self==state.game.player then state.control_base_done=true end
  return unpack(result,1,result.n)
 end
end
return M
