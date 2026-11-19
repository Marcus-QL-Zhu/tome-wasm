// Real Wasm; --source overlays current Lua modules in memory. Never mutates the frozen build.
import {readFile,writeFile,mkdir} from 'node:fs/promises';
import {resolve,dirname} from 'node:path';
import {pathToFileURL} from 'node:url';
const root=resolve(process.argv[2]),out=resolve(process.argv[3]),sourceOverlay=process.argv.includes('--source');
const {createKernel}=await import(pathToFileURL(resolve(root,'kernel_runtime.mjs')));
const {EngineBridge}=await import(pathToFileURL(resolve(root,'engine_bridge.mjs')));
const {default:createTome}=await import(pathToFileURL(resolve(root,'tome.js')));
const data=await readFile(resolve(root,'tome.data')),wasmBinary=await readFile(resolve(root,'tome.wasm'));
const files=['content_policy','worker','native_actions','formal_factory','formal_roster','native_catalog'];
const {installEncounter}=await import(pathToFileURL(resolve(root,'encounter_overlay.mjs')));
const manifest={format:'tome-encounter-v1',seed:23,map:{kind:'rooms',size:20},party:['184917','159442','425367'].map(template=>({template})),enemies:[{prototype:'orc warrior',kind:'rare',class:'Bulwark',level:10}]};
const cases=[['default',''],['paradox_birth',"c.party[1]={birth={sex='Male',race='Human',subrace='Cornac',class='Chronomancer',subclass='Paradox Mage'},level=18,stats={},talents={}}"],['paradox_rare',"c.enemies[1].class='Paradox Mage'"],['explicit_denied',"c.enemies[1].talents={{id='T_REVISIONIST_HISTORY',rank=1}}"],['unknown',"c.enemies[1].talents={{id='T_DOES_NOT_EXIST',rank=1}}"],['wanderer',"c.party[1]={birth={sex='Male',race='Human',subrace='Cornac',class='Adventurer',subclass='Wanderer'},level=18,stats={},talents={}}"]];
cases.push(['golem',"c.party[1]={birth={sex='Female',race='Human',subrace='Cornac',class='Mage',subclass='Alchemist'},level=1,stats={},talents={}}"]);
cases.push(['warden_birth',cases[1][1].replace('Paradox Mage','Temporal Warden')],['warden_rare',cases[2][1].replace('Paradox Mage','Temporal Warden')]);
cases.push(...[7,12,31].map(seed=>['random_'+seed,"for _,e in ipairs(c.enemies) do e.class=nil end"]));
const report=[];
for(const [name,fixture] of cases){
 let k, module;const logs=[];
 try{
  k=await createKernel(createTome,{wasmBinary,getPreloadedPackage:()=>data.buffer.slice(data.byteOffset,data.byteOffset+data.byteLength)},{prepare:async m=>{module=m;installEncounter(m,manifest);
   if(sourceOverlay)for(const f of files)m.FS.writeFile('/bundle/headless/'+f+'.lua',await readFile(resolve('tome_mvp/headless/'+f+'.lua'),'utf8'));
   if(name==='default'){const p='/bundle/headless/worker.lua';let s=m.FS.readFile(p,{encoding:'utf8'});const probe=`local s=create_scene(...)\n local p=s.player;local policy=require('content_policy');local Object=require('mod.class.Object');local defs=require('engine.interface.ActorTalents').talents_def\n for _,id in ipairs({'T_REVISIONIST_HISTORY','T_REVISIONIST_HISTORY_BACK','T_SEE_THE_THREADS','T_CEASE_TO_EXIST','T_PARADOX_CLONE','T_TEMPORAL_REPRIEVE','T_TEMPORAL_FUGUE','T_OVER_MIND','T_AMBUSCADE','T_PROJECTION','T_MECHARACHNID_PILOTING'}) do if defs[id] then\n local obj=Object.new{name='probe',use_talent={id=id,level=1,power=1},power=10};local before=p.talents[id];local ok,err=pcall(function()obj:useObject(p)end);assert(not ok and tostring(err):find('content policy') and p.talents[id]==before and obj.power==10);local t=defs[id];if t.action then local pass=pcall(t.action,p,t);assert(not pass) end;local pass=pcall(function()p:learnTalent(id,true,1)end);assert(not pass);pass=pcall(function()p:useTalent(id)end);assert(not pass)\n end end\n local pass=pcall(function()game:chronoClone('test')end);assert(not pass);pass=pcall(function()game:chronoRestore('test')end);assert(not pass);pass=pcall(function()policy.check_actor({descriptor={classes={'Paradox Mage'}}})end);assert(not pass);pass=pcall(function()policy.check_actor({auto_classes={{class='Paradox Mage'}}})end);assert(not pass);local enemy=assert(s.enemies[1])
    enemy:learnTalentType('chronomancy/timetravel',true)
    local valid,why=pcall(policy.check_actor,enemy)
    assert(not valid and tostring(why):find('content policy rejects talent tree: chronomancy/timetravel',1,true))
    enemy:unlearnTalentType('chronomancy/timetravel')
    policy.check_actor(enemy)
    print('POLICY_RUNTIME_OK');return s`;m.FS.writeFile(p,s.replace('return create_scene(...)',probe));}
   if(name==='golem'){
    const p='/bundle/headless/worker.lua',s=m.FS.readFile(p,{encoding:'utf8'});
    const anchor='bind_native_control(); bind_down_listener(true); refresh_visibility()';
    const check=";local golem=assert(state.player.alchemy_golem);assert(not golem.dead and state.game.party:hasMember(golem));assert(not require('native_control').allowed(state,golem));local ok,why=state.game.party:setPlayer(golem,true);assert(not ok and why=='secondary_body_control_disabled' and game.player==state.player);print('GOLEM_CONTROL_OK')";
    m.FS.writeFile(p,s.replaceAll(anchor,anchor+check));
   }
   if(name==='wanderer'){const p='/bundle/headless/worker.lua';let s=m.FS.readFile(p,{encoding:'utf8'});s=s.replace('return create_scene(...)', `local s=create_scene(...);local found=false;for _,tree in ipairs(s.player.randventurer_class_trees or {}) do if tree:match('^chronomancy/') then found=true end end;for _,tree in ipairs(s.player.randventurer_generic_trees or {}) do if tree:match('^chronomancy/') then found=true end end;assert(not found,'restricted chronomancy tree available');print('WANDERER_CHRONOMANCY_OK');return s`);m.FS.writeFile(p,s);}
   if(fixture){const p='/bundle/headless/worker.lua';const s=m.FS.readFile(p,{encoding:'utf8'});m.FS.writeFile(p,s.replace("local scenario = require 'scene'", "local scenario = require 'scene'\nlocal c=require('encounter_config');"+fixture));}
   },log:(...a)=>logs.push(a.join(' '))});
  const bridge=new EngineBridge(k.rpc);await bridge.init(name.startsWith('random_')?Number(name.slice(7)):23);
  const cat=await k.rpc('content_catalog',{},1);
  report.push({name,created:true,source_overlay:sourceOverlay,runtime_ok:name==='golem'?logs.some(x=>x.includes('GOLEM_CONTROL_OK')):name==='default'?logs.some(x=>x.includes('POLICY_RUNTIME_OK')):name==='wanderer'?logs.some(x=>x.includes('WANDERER_CHRONOMANCY_OK')):true,denied:cat.talents.filter(t=>t.policy_available===false).map(t=>t.id)});
 }catch(e){report.push({name,created:false,source_overlay:sourceOverlay,error:String(e),native_result:module?.cwrap('tome_result','string',[])(),logs:logs.filter(x=>/error|policy|lua|stack/i.test(x)).slice(-30)});}finally{k?.dispose();}
}
await mkdir(dirname(out),{recursive:true});await writeFile(out,JSON.stringify(report,null,2));
console.log(JSON.stringify(report));
const expected={golem:true,default:true,paradox_birth:false,paradox_rare:false,warden_birth:false,warden_rare:false,explicit_denied:false,unknown:false,wanderer:true,random_7:true,random_12:true,random_31:true};
const reasons={warden_birth:'content policy rejects class: Temporal Warden',warden_rare:'content policy rejects class: Temporal Warden',paradox_birth:'content policy rejects class: Paradox Mage',paradox_rare:'content policy rejects class: Paradox Mage',explicit_denied:'content policy rejects talent: T_REVISIONIST_HISTORY',unknown:'unknown native talent: T_DOES_NOT_EXIST'};
if(report.some(x=>x.created!==expected[x.name] || (reasons[x.name]&&!x.logs.some(l=>l.includes(reasons[x.name]))) || (x.created&&(!x.runtime_ok||!['T_PROJECTION','T_OVER_MIND','T_AMBUSCADE','T_TEMPORAL_FUGUE'].every(id=>x.denied.includes(id))||x.denied.includes('T_WAR_HOUND')))))process.exitCode=1;



