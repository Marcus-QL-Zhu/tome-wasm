import test from 'node:test';
import assert from 'node:assert/strict';
import {validateOperations} from '../scripts/tome_validate_operations.mjs';

test('scene query leaves baseline and scheduler unchanged',async()=>{
 const archive={format:'known',events:[]};let suspends=0,checkpoints=0;
 const session={suspended:true,bridge:{generation:2,boundary:'decision',state:()=>({turn:3})},suspend:async()=>{suspends++;},checkpoint:async()=>{checkpoints++;}};
 const kernel={rpc:async method=>method==='scene_query'?{rooms:[]}: {party:[]}};
 const result=await validateOperations(session,kernel,{archive,operations:[{operation:'scene_query'}],native_checkpoints:true});
 assert.equal(result.archive,archive);assert.equal(suspends,0);assert.equal(checkpoints,0);
});
test('stopped native loadout checkpoint does not issue pause',async()=>{
 let suspends=0;const b={generation:2,boundary:'decision',snapshot:{ai_status:'stopped'},state:()=>({turn:3})};
 const session={bridge:b,suspended:true,execute:async()=>({status:200,transition:{accepted:true}}),archive:async()=>({}),checkpoint:async()=>({format:'native'}),suspend:async()=>{suspends++;}};
 const result=await validateOperations(session,{rpc:async()=>({party:[]})},{archive:{},operations:[{operation:'campaign_items',world_id:'w',request:{}}],native_checkpoints:true});
 assert.equal(suspends,0);assert.equal(result.archive.format,'native');
});

test('catalog queries cannot share a transaction with mutation',async()=>{
 let called=false;const session={suspended:true};
 await assert.rejects(validateOperations(session,{rpc:async()=>{called=true;}},{archive:{},operations:[{operation:'scene_query'},{operation:'spawn_enemy'}]}),/must not be mixed/);
 assert.equal(called,false);assert.equal(session.suspended,true);
});
