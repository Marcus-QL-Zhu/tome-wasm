// Real Wasm with a test-only bootstrap insertion. No production fault switch.
import {readFile,writeFile,mkdir} from 'node:fs/promises';
import {resolve} from 'node:path';
import {pathToFileURL} from 'node:url';
const root=resolve(process.argv[2]);const out=resolve(process.argv[3]);
const {default:createTome}=await import(pathToFileURL(resolve(root,'tome.js')));
const bytes=await readFile(resolve(root,'tome.data'));const lines=[];
const mod=await createTome({wasmBinary:await readFile(resolve(root,'tome.wasm')),getPreloadedPackage:()=>bytes.buffer.slice(bytes.byteOffset,bytes.byteOffset+bytes.byteLength),print:(...p)=>lines.push(p.map(String).join(' ')),printErr:(...p)=>lines.push(p.map(String).join(' '))});
const fixture=String.raw`
do
 local s=require('scene').create(12,'formal')
 local V=require('headless_visuals');local P=require('engine.Particles')
 local before=rng.state_get();local life=s.player.life;local turn=game.turn
 for _,name in ipairs({'circle','never_seen_before','ice_nova','fireflash','melee_attack'}) do
  local h=s.map:particleEmitter(s.player.x,s.player.y,4,name,{radius=4})
  assert(h and h.__headless_visual==name and h.ps:isAlive())
  h:setSub('test_sub',1,{});h:shiftCustom(1,1);h:updateZoom();h:checkDisplay()
  assert(s.map:addParticleEmitter(h)==false)
  assert(s.map:removeParticleEmitter(h));s.map:removeParticleEmitters();assert(not h.ps:isAlive())
 end
 local h=P.new('arbitrary_display',1,{})
 assert(s.map:addParticleEmitter(h)==h);assert(s.map:addParticleEmitter(h)==false)
 assert(s.map:removeParticleEmitter(h));s.map:removeParticleEmitters();assert(not s.map:removeParticleEmitter(h))
 assert(s.player:addParticles(h)==h);s.player:removeParticles(h);h:dieDisplay()
 local blocked,err=pcall(function() V.new('meteor',1,{}).on_remove=function() error('never run') end end)
 assert(not blocked and tostring(err):find('unsupported_rule_bearing_visual_callback',1,true))
 local after=rng.state_get();assert(before.idx==after.idx)
 for i,v in ipairs(before.words) do assert(v==after.words[i]) end
 assert(s.player.life==life and game.turn==turn)
 print('PASS_VISUAL_HANDLE_AND_RULE_GUARD')
end
`;
const path='/bundle/headless/worker.lua', original=mod.FS.readFile(path,{encoding:'utf8'});
mod.FS.writeFile(path,original.replace("dofile('/probe.lua')","dofile('/probe.lua')\n"+fixture));
const init=mod.cwrap('tome_init','number',[]);const rc=init();
await mkdir(resolve(out,'..'),{recursive:true});await writeFile(out,JSON.stringify({rc,passed:lines.includes('PASS_VISUAL_HANDLE_AND_RULE_GUARD'),lines:lines.slice(-40)},null,2));
if(rc!==0 || !lines.includes('PASS_VISUAL_HANDLE_AND_RULE_GUARD'))throw Error('visual boundary probe failed; see report');
mod.cwrap('tome_free',null,[])();console.log('real Wasm visual boundary passed');
