import {readFile,writeFile,mkdir} from 'node:fs/promises';
import {resolve,dirname} from 'node:path';
import {pathToFileURL} from 'node:url';
import assert from 'node:assert/strict';
const root=resolve(process.argv[2]),output=resolve(process.argv[3]);
const {createKernel}=await import(pathToFileURL(resolve(root,'kernel_runtime.mjs')));
const {EngineBridge}=await import(pathToFileURL(process.argv.includes('--source-adapter')?resolve('tome_mvp/wasm/engine_bridge.mjs'):resolve(root,'engine_bridge.mjs')));
const {default:createTome}=await import(pathToFileURL(resolve(root,'tome.js')));
const bytes=await readFile(resolve(root,'tome.data')),logs=[],report={runtime:'real Wasm',source_adapter:process.argv.includes('--source-adapter'),fixture_override:true,scope:'native input and summon interfaces; enemies wait, not a combat survival test'};let k;
try{
 const fixture=String.raw`
local base_create=scenario.create
scenario.create=function(...)
 local s=base_create(...);local p=s.player
 local floor=s.map(p.x,p.y,s.Map.TERRAIN)
 for x=1,18 do for y=1,18 do s.map(x,y,s.Map.TERRAIN,floor:clone());s.map.lites(x,y,true) end end
 local actors={};for _,a in ipairs(s.allies) do actors[#actors+1]=a end;for _,a in ipairs(s.enemies) do actors[#actors+1]=a end
 for _,a in ipairs(actors) do s.map:remove(a.x,a.y,s.Map.ACTOR);a.x=nil;a.y=nil end
 for i,a in ipairs(actors) do a:move(3+i,10,true) end
 -- Interface checks must not depend on a particular class surviving repeated
 -- adjacent attacks while unrelated menus and native resources are exercised.
 for _,a in ipairs(s.enemies)do a.doAI=function(self)self:useEnergy()end end
 p:learnTalent(p.T_MANA_POOL,true,1,{no_unlearn=true});p.max_mana=1000;p.mana=1000
 p:learnTalent(p.T_WAR_HOUND,true,1,{no_unlearn=true});p.equilibrium=0
 p:learnTalent(p.T_ARCANE_COMBAT,true,1,{no_unlearn=true})
 p:learnTalent(p.T_MATTER_IS_ENERGY,true,1,{no_unlearn=true});p.psi=30;p.max_psi=100;p.psi_regen=0
 p:learnTalent(p.T_SPACETIME_TUNING,true,1,{no_unlearn=true});p.paradox=300;p.min_paradox=0;p.max_paradox=1000
 local gem=assert(game.zone:makeEntityByName(game.level,'object','GEM_AMETHYST'));assert(p:addObject(p.INVEN_INVEN,gem))
 p:learnTalent(p.T_FLAME,true,5,{no_unlearn=true});p:learnTalent(p.T_PHASE_DOOR,true,5,{no_unlearn=true})
 s.map.clean_fov=true;p:doFOV();return s
end
`;
 k=await createKernel(async options=>{const m=await createTome(options);if(process.argv.includes('--source-adapter')){for(const name of ['native_dialogs.lua','native_inputs.lua','scene.lua'])m.FS.writeFile('/bundle/headless/'+name,await readFile(resolve('tome_mvp/headless',name),'utf8'));}const path='/bundle/headless/worker.lua',source=m.FS.readFile(path,{encoding:'utf8'});m.FS.writeFile(path,source.replace("local scenario = require 'scene'","local scenario = require 'scene'\n"+fixture));return m;},{wasmBinary:await readFile(resolve(root,'tome.wasm')),getPreloadedPackage:()=>bytes.buffer.slice(bytes.byteOffset,bytes.byteOffset+bytes.byteLength)},{log:(...v)=>{logs.push(v.join(' '));if(logs.length>35)logs.shift();}});
 const b=new EngineBridge(k.rpc);let s=await b.init(23);
 async function command(body){const r=await b.command({...body,revision:s.revision});s=b.state();assert.equal(r.status,200,JSON.stringify(r));return s;}
 const flame=s.talents.find(t=>t.id==='T_FLAME');assert.equal(flame.target,'native');assert.equal(flame.available,true);
 s=await command({type:'talent',talent:'T_FLAME'});assert.equal(s.input_request.kind,'target');assert.equal(s.advance_status,'await_input');report.target_request=s.input_request;
 const input=s.input_request.id;const before=s.turn;
 const bad=await b.command({type:'input_response',input_id:input+10,x:6,y:10,revision:s.revision});assert.equal(bad.status,400);assert.equal(b.locked,false);s=b.state();
 s=await command({type:'input_response',input_id:input,cancel:true});assert.equal(s.input_request,null);assert.equal(s.turn,before);report.cancelled=true;
 s=await command({type:'talent',talent:'T_FLAME'});const enemy=s.enemies[0];assert.ok(enemy);
 s=await command({type:'input_response',input_id:s.input_request.id,x:enemy.x,y:enemy.y});assert.equal(s.input_request,null);assert.ok(s.talents.find(t=>t.id==='T_FLAME').cooldown>0);report.cast=true;
 s=await command({type:'talent',talent:'T_PHASE_DOOR'});assert.equal(s.input_request.kind,'target');
 s=await command({type:'input_response',input_id:s.input_request.id,x:s.party[0].x,y:s.party[0].y});assert.equal(s.input_request.kind,'target');report.second_request=s.input_request;
 s=await command({type:'input_response',input_id:s.input_request.id,x:4,y:6});assert.equal(s.input_request,null);assert.ok(s.talents.find(t=>t.id==='T_PHASE_DOOR').cooldown>0);report.multi_stage=true;report.end={turn:s.turn,x:s.party[0].x,y:s.party[0].y};s=await command({type:'talent',talent:'T_ARCANE_COMBAT'});assert.equal(s.input_request.kind,'choice');report.menu=s.input_request;
 const random=s.input_request.options.find(o=>o.label.includes('Random spells'));assert.ok(random);
 s=await command({type:'input_response',input_id:s.input_request.id,choice:random.id});assert.equal(s.input_request,null);assert.equal(s.talents.find(t=>t.id==='T_ARCANE_COMBAT').active,true);report.native_menu=true;
 s=await command({type:'talent',talent:'T_MATTER_IS_ENERGY'});assert.equal(s.input_request.kind,'choice');report.inventory_menu=s.input_request;
 const gem=s.input_request.options.find(o=>o.label.toLowerCase().includes('amethyst'));assert.ok(gem);s=await command({type:'input_response',input_id:s.input_request.id,choice:gem.id});assert.equal(s.input_request,null);assert.ok(s.talents.find(t=>t.id==='T_MATTER_IS_ENERGY').cooldown>0);report.native_inventory=true;
 s=await command({type:'talent',talent:'T_SPACETIME_TUNING'});assert.equal(s.input_request.kind,'quantity');report.quantity=s.input_request;
 s=await command({type:'input_response',input_id:s.input_request.id,value:250});assert.equal(s.input_request,null);report.native_quantity=true;
 s=await command({type:'talent',talent:'T_WAR_HOUND'});assert.equal(s.input_request.kind,'target');s=await command({type:'input_response',input_id:s.input_request.id,x:s.party[0].x,y:s.party[0].y-1});
 const summon=(s.entities || []).find(a=>a.name==='war hound');assert.ok(summon,'native summon missing from observation');assert.ok(!s.enemies.some(a=>a.id===summon.id));report.summon={id:summon.id,name:summon.name,hp:summon.hp};report.passed=true;
}catch(e){report.error=String(e.stack || e);process.exitCode=1;}
finally{k?.dispose();report.logs=logs;await mkdir(dirname(output),{recursive:true});await writeFile(output,JSON.stringify(report,null,2));console.log(JSON.stringify({output,passed:report.passed,error:report.error?.slice(0,1400)}));}
