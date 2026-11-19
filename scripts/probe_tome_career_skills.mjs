// Run a native class skill on a fresh birth so another skill cannot satisfy its checks.
import {readFile,writeFile} from 'node:fs/promises';
import {resolve} from 'node:path';
import {pathToFileURL} from 'node:url';
const [directory,output,parent,career]=process.argv.slice(2);
const root=resolve(directory),load=name=>import(pathToFileURL(resolve(root,name)));
const {createKernel}=await load('kernel_runtime.mjs'),{EngineBridge}=await load('engine_bridge.mjs');
const {default:createTome}=await load('tome.js');
const data=await readFile(resolve(root,'tome.data')),wasmBinary=await readFile(resolve(root,'tome.wasm'));
const {installEncounter}=await load('encounter_overlay.mjs');
const manifest={format:'tome-encounter-v1',seed:23,map:{kind:'rooms',size:20},party:['184917','159442','425367'].map(template=>({template})),enemies:[{prototype:'orc warrior',level:10}]};
const report={career,skills:[]};
let mod,kernel,logs,fixture,catalog,nativeAction;
async function start(tid){
 logs=[];nativeAction=false;
 const race=career==='Stone Warden'?'Dwarf':'Human',subrace=race==='Human'?'Cornac':race;
 fixture=`local c=require('encounter_config');c.party[1]={birth={sex='Male',race=${JSON.stringify(race)},subrace=${JSON.stringify(subrace)},class=${JSON.stringify(parent)},subclass=${JSON.stringify(career)}},level=50,stats={},talents={}}
 local original=scenario.create
 scenario.create=function(...)
  local s=original(...);local p=s.player;local policy=require('content_policy')
  local ids=require('json_validate').array()
  for tree in pairs(p.talents_types) do
   local def=p:getTalentTypeFrom(tree)
   for _,t in ipairs(def and def.talents or {}) do
    if not t.hide and not t.no_levelup and policy.allowed_talent(t.id) then ids[#ids+1]=t.id end
   end
  end
  table.sort(ids);print('SKILL_IDS',require('json_validate').encode(ids))
  ${tid?`if not p:knowTalent('${tid}') then p:learnTalent('${tid}',true,1) end`:''}
  ${tid==='T_IMBUE_ITEM'?`assert(p:addObject(p.INVEN_INVEN,assert(game.zone:makeEntityByName(game.level,'object','GEM_AGATE'))))
  local armor=assert(game.zone:makeEntity(game.level,'object',{type='armor',subtype='cloth',no_unique=true},nil,true));assert(p:addObject(p.INVEN_INVEN,armor))
  for i,a in ipairs(s.allies) do a._dm_world_id='fixture-'..i end
  require('campaign_items').adopt(s,'probe-world','probe-campaign')`:''}
  ${tid&&process.argv.includes('--prepared')?`p.life=p.max_life*0.4
  local target=p:getTalentFromId('${tid}')
  for _,t in ipairs(p:getTalentTypeFrom(target.type[1]).talents) do
   if t.type[2]<target.type[2] and policy.allowed_talent(t.id) and not p:knowTalent(t.id) then p:learnTalent(t.id,true,1) end
  end
  for _,r in ipairs(p.resources_def) do
   if type(p[r.short_name])=='number' and type(p[r.maxname])=='number' then
    p[r.incFunction](p,r.switch_direction and -p[r.maxname] or p[r.maxname])
   end
  end`:''}
  local foe=s.enemies[1]
  if foe then
   for dx=-1,1 do for dy=-1,1 do
    local x,y=p.x+dx,p.y+dy
    if not s.map:checkAllEntities(x,y,'block_move',foe) then foe:move(x,y,true);foe=nil;break end
   end;if not foe then break end end
  end
  s.map.clean_fov=true;p:doFOV()
  ${tid&&process.argv.includes('--context')?`local id='${tid}'
  if p.descriptor.subclass=='Oozemancer' and not p:isTalentActive(p.T_PSIBLADES) then
   p:learnTalent(p.T_PSIBLADES,true,1);p:forceUseTalent(p.T_PSIBLADES,{ignore_energy=true})
  end
  if id=='T_AEGIS' then p:setEffect(p.EFF_DAMAGE_SHIELD,9,{power=200}) end
  if id=='T_WATERS_OF_LIFE' or id=='T_CAUTERIZE_SPIRIT' or id=='T_CLEANSING_FLAMES' then p:setEffect(p.EFF_POISONED,9,{src=s.enemies[1],power=10}) end
  if id=='T_RELENTLESS_FURY' then p:incStamina(-p:getMaxStamina()*0.8) end
  if id=='T_SLAM' then p:learnTalent(p.T_RAMPAGE,true,1);p:forceUseTalent(p.T_RAMPAGE,{ignore_energy=true}) end
  if id=='T_MERGEBACK' or id=='T_DWARVEN_UNITY' then p:learnTalent(p.T_ELEMENTAL_SPLIT,true,1);p:forceUseTalent(p.T_ELEMENTAL_SPLIT,{ignore_energy=true}) end
  if id=='T_CONVERSION' or id=='T_RESONANCE_FIELD' or id=='T_FEEDBACK_LOOP' then p:incFeedback(80) end
  if id=='T_FURNACE_VENT' then p:setEffect(p.EFF_FURNACE_MOLTEN_POINT,8,{power=5}) end
  if id=='T_PHASE_SUMMON' or id=='T_DETONATE' or id=='T_WILD_SUMMON' then
   p:learnTalent(p.T_WAR_HOUND,true,1);local e=s.enemies[1];p:forceUseTalent(p.T_WAR_HOUND,{ignore_energy=true,force_target=e})
  end`:''}
  ${tid?`local post=p.postUseTalent
  p.postUseTalent=function(actor,t,ret,...)
   local result=post(actor,t,ret,...)
   if t.id=='${tid}' and ret and result then print('PROBE_NATIVE_ACTION',t.id) end
   return result
  end`:''}
  return s
 end`;
 kernel=await createKernel(async options=>{mod??=await createTome(options);return mod;},
  {wasmBinary,getPreloadedPackage:()=>data.buffer.slice(data.byteOffset,data.byteOffset+data.byteLength)},
  {log:(...v)=>{const s=v.join(' ');if(s.includes('PROBE_NATIVE_ACTION')&&s.endsWith(tid))nativeAction=true;else if(s.includes('SKILL_IDS'))catalog=JSON.parse(s.slice(s.indexOf('SKILL_IDS')+9).trim());else {logs.push(s.slice(-1000));if(logs.length>70)logs.shift();}},
   prepare(m){installEncounter(m,manifest);const p='/bundle/headless/worker.lua',source=m.FS.readFile(p,{encoding:'utf8'}),key="local scenario = require 'scene'";m.FS.writeFile(p,source.replace(key,key+'\n'+fixture));}});
 const bridge=new EngineBridge(kernel.rpc);await bridge.init(23);return bridge;
}
try{
 await start();const ids=[...new Set(catalog)];kernel.dispose();
 report.catalog=ids;
 const selection=process.argv[6] && process.argv[6]!=='--catalog' ? JSON.parse(await readFile(process.argv[6],'utf8')) : null;
 for(const id of ids.filter(id=>!process.argv.includes('--catalog')&&(!selection||selection.includes(id)))){
  const entry={id};report.skills.push(entry);
  try{
   const b=await start(id);let s=b.state();const t=s.talents.find(t=>t.id===id);
   if(!t){entry.status='not_exposed';continue;}
   if(t.mode==='passive'){entry.status='passive_learned';continue;}
   if(!t.available){entry.status='prerequisite';entry.reason=t.reason;continue;}
   let before;
   const command=async body=>{const r=await b.command({...body,revision:s.revision});if(r.status!==200)throw Error([body.type,JSON.stringify(r),s.status,s.advance_status,JSON.stringify(s.input_request)?.slice(0,220)].join(' ').slice(0,560));s=b.state();};
   for(let i=0;i<120;i++){
    if(s.input_request)await command({type:'input_response',input_id:s.input_request.id,cancel:true});
    else if(s.capabilities.continue_pending)await command({type:'continue_pending'});
    else break;
   }
   if(b.state().capabilities.continue_pending||s.input_request){entry.status='setup_pending';continue;}
   nativeAction=false;before=s.turn;
   let first={type:'talent',talent:id};
   if(t.target==='hostile'&&s.enemies[0])first.target=s.enemies[0].id;
   if(t.target==='grid'&&s.enemies[0]){first.x=s.enemies[0].x;first.y=s.enemies[0].y;}
   await command(first);
   for(let i=0;s.input_request&&i<6;i++){
    const q=s.input_request,a={type:'input_response',input_id:q.id};
    if(q.kind==='target'){const e=s.enemies.find(e=>!e.dead)||s.party[0];a.x=e.x;a.y=e.y;}
    else if(q.kind==='choice'&&q.options?.some(o=>o.enabled!==false))a.choice=q.options.find(o=>o.enabled!==false).id;
    else if(q.kind==='quantity')a.value=q.min??1;
    else break;
    await command(a);
   }
   if(id==='T_IMBUE_ITEM'){
    const inspect=await kernel.rpc('dm_inspect',{},b.generation);
    const armor=inspect.party[0].inventory.find(i=>i.imbued);if(!armor)throw Error('native armour lacks permanent gem');
    const receipt=await kernel.rpc('campaign_reconcile',{world_id:'probe-world',world_location:'fixture-site',observation_id:'imbue'},b.generation);
    if(!JSON.stringify(receipt).includes('consumed'))throw Error('gem consumption not reconciled');
   }
   const after=s.talents.find(t=>t.id===id);
   entry.status=s.input_request?'input_required':after?.active||after?.cooldown>0?'activated':nativeAction?'native_action_confirmed':s.turn!==before?'turn_advanced':'no_effect_observed';
   if(logs.some(l=>l.includes('HEADLESS_TALENT_ERROR_STACK_JSON')))entry.status='native_error';
  }catch(e){entry.status='needs_fixture_or_fix';entry.reason=String(e).slice(0,560);entry.native=logs.slice(-22);}
  finally{kernel?.dispose();kernel=null;if(report.skills.length%20===0)await writeFile(output,JSON.stringify(report));}
 }
}catch(e){report.error=String(e);report.logs=logs?.slice(-8);process.exitCode=1;}
finally{kernel?.dispose();await writeFile(output,JSON.stringify(report,null,2));}
