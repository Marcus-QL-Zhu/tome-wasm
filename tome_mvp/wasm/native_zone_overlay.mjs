// Narrow source-port compatibility. Native decisions and RNG stay unchanged.
export function installNativeZoneFixes(mod,{mission=false}={}){
 const patch=(path,needle,replacement)=>{
  const source=mod.FS.readFile(path,{encoding:'utf8'});
  if(source.includes(replacement))return;
  if(source.split(needle).length!==2)throw Error('unknown native Zone source site: '+path);
  mod.FS.writeFile(path,source.replace(needle,replacement));
 };
 const traps='/bundle/tome/data/talents/cunning/traps.lua';
 // LuaJIT accepts boolean %s arguments; the Lua 5.1 port requires tostring.
 patch(traps,'range, tgt_dist, defense))','range, tgt_dist, tostring(defense)))');
 patch(traps,'grid[1], grid[2], px, py, ok))','grid[1], grid[2], px, py, tostring(ok)))');
 patch('/bundle/tome/mod/class/GameState.lua','b.on_melee_hit = {}',
  "if headless_before_retal_clear then headless_before_retal_clear(b) end\n\t\t\t\tb.on_melee_hit = {}");
 const trollDamage='self.inc_damage={[engine.DamageType.FIRE]=math.min(self.level*2,50),}';
 patch('/bundle/tome/data/general/npcs/troll.lua',trollDamage,
  'if headless_before_troll_damage_clear then headless_before_troll_damage_clear(self) end\n\t\t'+trollDamage);
 for(const path of ['psionic/slumber','corruptions/shadowflame']){
  patch('/bundle/tome/data/talents/'+path+'.lua',
   'not (self.player and self.game_ender) then return nil end',
   "not require('content_policy').plane_player(self) then return nil end");
 }
 const dream='/bundle/tome/data/talents/psionic/slumber.lua';
 patch(dream,'if self:attr("is_psychic_projection") then if not silent',
  'if not headless_plane_cast_allowed(self,t.id) then return false end; if self:attr("is_psychic_projection") then if not silent');
 const fear='/bundle/tome/data/talents/corruptions/shadowflame.lua';
 patch(fear,'return not (game.zone.is_demon_plane or game.zone.no_planechange)',
  'return headless_plane_cast_allowed(self,t.id) and not (game.zone.is_demon_plane or game.zone.no_planechange)');
 patch(fear,'return self.ai_target.actor and self.ai_target.actor.game_ender or self.sustain_talents[t.id] end',
  'return self.sustain_talents[t.id] or (not game.party:hasMember(self) and self.ai_target.actor and self.ai_target.actor.game_ender) end');
 // Keep the lore event and skip the desktop-only modal.
 patch(fear,'game.party:learnLore("fearscape-entry")','game.party:learnLore("fearscape-entry", true)');
 patch(dream,'game.party:learnLore("dreamscape-entry")','game.party:learnLore("dreamscape-entry", true)');
 if(mission){
  const query=`elseif req.method=='scene_query' then
        last_id=id
        if not state then reject(id,'not_created')
        elseif req.expected_generation~=generation then reject(id,'stale_generation')
        else
            local ok,result=xpcall(function() return require('scene_placement').query(state,req.params) end,debug.traceback)
            if ok then reply(id,result)else print(tostring(result));reject(id,'scene_query_failed')end
        end
    elseif req.method=='content_catalog' then`;
  patch('/bundle/headless/worker.lua',"elseif req.method=='content_catalog' then",query);
  const line='for _,foe in ipairs(state.enemies) do if not foe.dead then return false end end';
  patch('/bundle/headless/worker.lua',line,line+`\n    if state_fixture=='formal' and require('encounter_config') and require('encounter_config').zone then
        for _,actor in pairs(state.game.level.entities)do
            if not actor.dead and actor.life and actor.reactionToward and actor:reactionToward(state.player)<0 then return false end
        end
    end`);
 }
}
