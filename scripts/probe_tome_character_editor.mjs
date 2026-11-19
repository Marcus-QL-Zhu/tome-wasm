// Isolated native rules probe. Injects fixture identities and an illegal item, never touches player saves.
import {readFile,writeFile} from 'node:fs/promises';import {resolve}from'node:path';import{pathToFileURL}from'node:url';import assert from'node:assert/strict';
const root=resolve(process.argv[2]||'artifacts/native-partition-warm-20261115/candidate6/public');const{createKernel}=await import(pathToFileURL(resolve(root,'kernel_runtime.mjs')));const{default:createTome}=await import(pathToFileURL(resolve(root,'tome.js')));const bytes=await readFile(resolve(root,'tome.data')),wasmBinary=await readFile(resolve(root,'tome.wasm')),logs=[];
const k=await createKernel(createTome,{wasmBinary,getPreloadedPackage:()=>bytes.buffer.slice(bytes.byteOffset,bytes.byteOffset+bytes.byteLength)},{prepare:async m=>{for(const n of ['worker','character_editor','campaign_loadout','campaign_items','dm_native','localization'])m.FS.writeFile('/bundle/headless/'+n+'.lua',await readFile('tome_mvp/headless/'+n+'.lua','utf8'));let p='/bundle/headless/formal_scene.lua',s=m.FS.readFile(p,{encoding:'utf8'});s=s.replace('return state','for i,a in ipairs(state.allies) do a._dm_world_id="person"..i end; state._dm_items_world="world";local a=state.allies[1];local o=a:getInven(a.INVEN_BODY)[1]:clone();o.require={level=99};a:addObject(a.INVEN_INVEN,o);return state');m.FS.writeFile(p,s);},log:(...s)=>logs.push(s.join(' '))});

try{
 const created=await k.rpc('create',{seed:7,fixture:'formal'}),gen=created.generation;
 await k.rpc('campaign_adopt',{world_id:'world',campaign_id:'test'},gen);
 let native=await k.rpc('dm_inspect',{},gen),id=native.party[0].world_id;
 let sheet=await k.rpc('character_editor',{operation:'open',actor_id:id},gen);
 assert.equal(sheet.refund_limits.class,4);assert.equal(sheet.refund_limits.generic,3);assert.ok(sheet.categories.length);
 const initial=structuredClone(sheet),stat=sheet.stats.find(s=>s.can_add);assert.ok(stat);
 let r=await k.rpc('character_editor',{operation:'edit',actor_id:id,step:{kind:'stat',id:stat.id,delta:1}},gen);assert.ok(r.accepted);assert.equal(r.sheet.points.stats,initial.points.stats-1);
 r=await k.rpc('character_editor',{operation:'edit',actor_id:id,step:{kind:'stat',id:stat.id,delta:-1}},gen);assert.ok(r.accepted);assert.equal(r.sheet.points.stats,initial.points.stats);
 r=await k.rpc('character_editor',{operation:'edit',actor_id:id,step:{kind:'stat',id:stat.id,delta:-1}},gen);assert.equal(r.accepted,false);
 let t=initial.categories.flatMap(x=>x.talents).find(t=>t.can_add);assert.ok(t);
 r=await k.rpc('character_editor',{operation:'edit',actor_id:id,step:{kind:'talent',id:t.id,delta:1}},gen);assert.ok(r.accepted,JSON.stringify(r));let ranked=r.sheet.categories.flatMap(x=>x.talents).find(x=>x.id===t.id);assert.equal(ranked.rank,t.rank+1);assert.ok(ranked.can_remove);
 r=await k.rpc('character_editor',{operation:'edit',actor_id:id,step:{kind:'talent',id:t.id,delta:-1}},gen);assert.ok(r.accepted);assert.equal(r.sheet.categories.flatMap(x=>x.talents).find(x=>x.id===t.id).rank,t.rank);
 const denied=initial.categories.flatMap(x=>x.talents).find(t=>!t.can_add&&t.rank<t.max);if(denied){r=await k.rpc('character_editor',{operation:'edit',actor_id:id,step:{kind:'talent',id:denied.id,delta:1}},gen);assert.equal(r.accepted,false);}
 await k.rpc('character_editor',{operation:'finish',actor_id:id},gen);
 const forbidden=native.party[0].inventory.find(i=>i.slot==='INVEN'&&i.description.includes('99'));assert.ok(forbidden,'restriction fixture');
 const before=await k.rpc('dm_inspect',{},gen);await assert.rejects(k.rpc('character_editor',{operation:'equipment',actor_id:id,request:{operation:'equip',actor_id:id,item_id:forbidden.item_id,slot:'BODY',position:1,action_id:'denied'}},gen));
 const after=await k.rpc('dm_inspect',{},gen);assert.deepEqual(after.party.map(p=>p.inventory),before.party.map(p=>p.inventory));
 console.log(JSON.stringify({passed:true,categories:initial.categories.length,talent:t.id,stats_refund:true,talent_refund:true,base_stats_not_refundable:true,prerequisite_rejected:!!denied,equipment_requirement_rejected:true,inventory_unchanged:true}));
}catch(e){console.log(logs.slice(-8).join('\n'));throw e}finally{k.dispose()}
