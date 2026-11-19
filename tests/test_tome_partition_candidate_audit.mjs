import test from 'node:test';
import assert from 'node:assert/strict';
import {buildPartitionCandidate} from '../scripts/tome_partition_candidate.mjs';

// A minimal native transport stand-in. Exercise the actual candidate builder,
// including operation dispatch, stopped boundary and partition normalization.
test('a reused session appends each request audit once',async()=>{
 const scope={build:'test-build',world_id:'world',campaign_id:'campaign'};
 const session={seed:1,partitionOnly:true,nativeBoundary:'campaign_admin',events:[{kind:'campaign_items',body:{old:true}}],
  bridge:{generation:1,revision:0,epoch:0,reason:null,boundary:'decision',snapshot:{area_outside:true,map_available:false,ai_status:'idle'},state:()=>({turn:0})},
  async execute(kind,body){this.events.push({kind,body:structuredClone(body)});return {status:200,transition:{kind}};}};
 session.bridge.rpc=async()=>({format:'tome-partitioned-native-v1',generation:1,boundary:'decision',native_boundary:'campaign_admin',world_id:scope.world_id,campaign_id:scope.campaign_id,
  objects:{'r:1':{owner:'hot',kind:'table'}},next_ref:2,next_uid:1,
  descriptors:[{partition_id:'hot',kind:'hot',root_ref:'r:1',strong_refs:[]}],
  dirty_blobs:[{partition_id:'hot',root_ref:'r:1',strong_refs:[],payload_base64:'aG90',bytes:3}]});
 const kernel={rpc:async()=>({party:[]})};
 const ops=label=>[{operation:'campaign_items',world_id:'world',request:{label}},{operation:'campaign_reconcile',world_id:'world',world_location:'tile',observation_id:label}];
 const previous=[{kind:'campaign_adopt',body:{campaign_id:'campaign'}}];
 const first=await buildPartitionCandidate({session,kernel,scope,prior:null,residentIds:['hot'],operations:ops('first'),priorAudit:previous,nextVersion:2});
 assert.equal(first.candidate.archive.audit.length,3);
 assert.deepEqual(first.candidate.archive.audit.map(e=>e.kind),['campaign_adopt','campaign_items','campaign_reconcile']);
 const second=await buildPartitionCandidate({session,kernel,scope,prior:first.candidate.manifest,residentIds:['hot'],operations:ops('second'),priorAudit:first.candidate.archive.audit,nextVersion:3});
 const audit=second.candidate.archive.audit;
 assert.equal(audit.length,5);
 assert.deepEqual(audit.filter(e=>e.kind==='campaign_items').map(e=>e.body.request.label),['first','second']);
 assert.equal(session.events.length,5); // Builder does not confirm or clear a pending VM.
 assert.deepEqual(previous,[{kind:'campaign_adopt',body:{campaign_id:'campaign'}}]);
 assert.equal(first.candidate.archive.audit.length,3);
});
