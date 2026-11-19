// Native descriptor matrix. This is a controlled config probe, not a complete
// skill/AI certification. It never changes original ToME birth/rule functions.
import {readFile,writeFile,mkdir} from 'node:fs/promises';
import {resolve,dirname} from 'node:path';
import {pathToFileURL} from 'node:url';
const root=resolve(process.argv[2]),output=resolve(process.argv[3]),sourceCatalog=process.argv.includes('--source-catalog');
const {createKernel}=await import(pathToFileURL(resolve(root,'kernel_runtime.mjs')));
const {EngineBridge}=await import(pathToFileURL(resolve(root,'engine_bridge.mjs')));
const {default:createTome}=await import(pathToFileURL(resolve(root,'tome.js')));
const bytes=await readFile(resolve(root,'tome.data')),wasmBinary=await readFile(resolve(root,'tome.wasm'));
const report={runtime:'real Wasm',fixture_override:true,source_catalog_overlay:sourceCatalog,all_skills_verified:false,cases:[]};
const lua=value=>typeof value==='string'?JSON.stringify(value):typeof value==='number'?String(value):Array.isArray(value)?'{'+value.map(lua).join(',')+'}':value&&typeof value==='object'?'{'+Object.entries(value).map(([k,v])=>'['+lua(k)+']='+lua(v)).join(',')+'}':value===true?'true':value===false?'false':'nil';
async function make(birth){
 const logs=[];const k=await createKernel(async options=>{
  const m=await createTome(options);
  if(sourceCatalog)m.FS.writeFile('/bundle/headless/native_catalog.lua',await readFile(resolve('tome_mvp/headless/native_catalog.lua'),'utf8'));
  if(birth){
   const path='/bundle/headless/worker.lua',source=m.FS.readFile(path,{encoding:'utf8'});
   const fixture=`local c=require('encounter_config');c.party[1]={birth=${lua({sex:'Male',race:birth.race||'Human',subrace:birth.subrace||'Cornac',class:birth.class||'Warrior',subclass:birth.subclass||'Bulwark'})},name='Birth probe',level=18,stats={},talents={}}\nlocal base_create=scenario.create;scenario.create=function(...)local s=base_create(...);local p=s.player;local trees=require('json_validate').object({});for id,v in pairs(p.talents_types)do if v then trees[id]=true end end;local quests=require('json_validate').array();for id in pairs(p.quests or {})do quests[#quests+1]=tostring(id)end;table.sort(quests);print('BIRTH_FEATURES:'..require('json_validate').encode(require('json_validate').object({seed=p.randventurer_seed or '',trees=trees,quests=quests,golem=not not p.alchemy_golem,custom_pending=not not p.custom_birthend})));return s end\n`;
   m.FS.writeFile(path,source.replace("local scenario = require 'scene'","local scenario = require 'scene'\n"+fixture));
  }
  return m;
 },{wasmBinary,getPreloadedPackage:()=>bytes.buffer.slice(bytes.byteOffset,bytes.byteOffset+bytes.byteLength)},{log:(...v)=>{logs.push(v.join(' '));if(logs.length>35)logs.shift();}});
 return {k,logs};
}
let initial;
try{
 initial=await make();const b=new EngineBridge(initial.k.rpc);await b.init(23);const catalog=await initial.k.rpc('content_catalog',{},1);report.catalog={talents:catalog.talents.length,births:catalog.class_births.length,races:catalog.race_births.length,npc_sources:catalog.npc_sources.length};
 const negative=[{axis:'negative',class:'Mage',subclass:'Bulwark'},{axis:'negative',race:'Human',subrace:'Ghoul',class:'Warrior',subclass:'Bulwark'},{axis:'negative',race:'Undead',subrace:'Ghoul',class:'Wilder',subclass:'Wyrmic'},{axis:'negative',race:'Human',subrace:'Cornac',class:'Wilder',subclass:'Stone Warden'}];
 for(const birth of (process.argv.includes('--negative-only')?negative:[...catalog.class_births.map(b=>({...b,axis:'class'})),...catalog.race_births.map(b=>({...b,axis:'race'}))])){
  let x;const start=performance.now();
  try{
   if(birth.axis!=='negative' && birth.subclass==='Stone Warden'){birth.race='Dwarf';birth.subrace='Dwarf';}
   if(birth.subclass==='None'){birth.race='Construct';birth.subrace='Runic Golem';}
   if(birth.subrace==='Runic Golem'){birth.class='None';birth.subclass='None';}
   x=await make(birth);const bridge=new EngineBridge(x.k.rpc);await bridge.init(23);const s=bridge.state();
   const result=await bridge.command({type:'wait',revision:bridge.revision});
   if(result.status!==200)throw Error('wait failed: '+JSON.stringify(result.body).slice(0,250));
   const features=JSON.parse(x.logs.find(v=>v.startsWith('BIRTH_FEATURES:')).slice(15));
   if(features.custom_pending)throw Error('unfinished custom birth');
   if(birth.subclass==='Wanderer' && (!features.seed || Object.keys(features.trees).length<4))throw Error('Wanderer trees missing');
   if(birth.subclass==='Alchemist' && !features.golem)throw Error('native golem missing');
   report.cases.push({...birth,features,created:true,wait:true,party:s.party.length,talents:s.talents.length,hp:s.party[0].hp,resources:s.party[0].resources,ms:performance.now()-start});
  }catch(e){report.cases.push({...birth,expected_rejection:(birth.subclass==='Tutorial Adventurer'||birth.axis==='negative') && x?.logs.some(v=>v.includes('native birth combination denied')),created:false,error:String(e.stack||e).slice(0,2200),logs:x?.logs,ms:performance.now()-start});}
  finally{x?.k.dispose();}
 }
 report.created=report.cases.filter(c=>c.created).length;report.expected_rejections=report.cases.filter(c=>c.expected_rejection).length;report.failed=report.cases.length-report.created-report.expected_rejections;
}catch(e){report.error=String(e.stack||e);report.logs=initial?.logs;process.exitCode=1;}
finally{initial?.k.dispose();await mkdir(dirname(output),{recursive:true});await writeFile(output,JSON.stringify(report,null,2));console.log(JSON.stringify({output,catalog:report.catalog,created:report.created,failed:report.failed,expected_rejections:report.expected_rejections,error:report.error,failures:report.cases.filter(c=>!c.created&&!c.expected_rejection).map(({class:parent,subclass,race,subrace,error})=>({class:parent,subclass,race,subrace,error:error.slice(0,400)}))}));}
