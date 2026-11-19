dofile('/probe.lua')
local scenario=require 'scene'
local snapshot=require 'snapshot_experiment'
local json=require 'json_validate'
local s=scenario.create(11)
local function wait(st)
    st.player:waitTurn()
    for i=1,30 do if game.paused and st.player:enoughEnergy() then break end; game:tick() end
    st.map.clean_fov=true; st.player:doFOV()
end
local function summary(st)
    local result={st.game.turn, tostring(st.enemy:hasEffect(st.enemy.EFF_OFFBALANCE) and st.enemy:hasEffect(st.enemy.EFF_OFFBALANCE).dur), tostring(st.player.talents_cd[st.player.T_RUSH]), tostring(st.player:getStamina()), tostring(st.player:getInven('QUIVER')[1].combat.shots_left), tostring(world:hasSeenZone('kernel'))}
    for _,a in ipairs(st.allies) do for _,v in ipairs({a.uid,a.x,a.y,a.life,a.energy.value}) do result[#result+1]=string.format('%.17g',v) end end
    for _,a in ipairs(st.enemies) do for _,v in ipairs({a.uid,a.x,a.y,a.life,a.energy.value}) do result[#result+1]=string.format('%.17g',v) end end
    local r=rng.state_get()
    result[#result+1]=tostring(r.index)
    for _,v in ipairs(r.words) do result[#result+1]=tostring(v) end
    return table.concat(result,'|')
end
local input=assert(json.decode(protocol_read()))
local restored=snapshot.restore(input.doc,s)
for i=1,3 do wait(restored); assert(input.expected[i]==summary(restored),'rush trajectory mismatch '..i) end
protocol_write('PASS_RUSH_CROSS_PROCESS_THREE_WAITS\n')
