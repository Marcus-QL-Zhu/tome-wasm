// Shared operation semantics for the one-shot and resident validators.
// Callers own archive admission, VM lifecycle, and durable commit.
export async function executeNativeOperations(session,kernel,request){
 const ops=request.operations || [];
 if(ops.some(op=>op.operation==='scene_query') && ops.some(op=>op.operation!=='scene_query'))throw Error('scene queries must not be mixed with mutations');
 session.suspended=false;
 const results=[];
 for(const operation of request.operations || []){
  if(operation.operation==='scene_query'){
   results.push(await kernel.rpc('scene_query',operation.query || {},session.bridge.generation));
   continue;
  }
  const kind=['campaign_next','campaign_items','campaign_adopt','campaign_reconcile','campaign_settle','campaign_wipeout'].includes(operation.operation)?operation.operation:'dm_transition';
  if(!['recruit','surrender','spawn_enemy','grant_experience','area_enter','area_depart','campaign_next','campaign_items','campaign_adopt','campaign_reconcile','campaign_settle','campaign_wipeout'].includes(operation.operation))throw Error('unsupported DM operation');
  const body=kind==='campaign_next'?operation.scene:kind==='campaign_items'?{world_id:operation.world_id,request:operation.request}:kind==='campaign_adopt'?{world_id:operation.world_id,campaign_id:operation.campaign_id}:kind==='campaign_reconcile'?{world_id:operation.world_id,world_location:operation.world_location,observation_id:operation.observation_id}:kind==='campaign_wipeout'?{world_id:operation.world_id,world_location:operation.world_location,...(operation.victor_id?{victor_id:operation.victor_id}:{})}:kind==='campaign_settle'?{}:operation;
  const result=await session.execute(kind,body);if(result.status!==200)throw Error('DM transition failed');
  results.push(result.transition);
  if(kind==='campaign_next' || kind==='dm_transition' && operation.operation==='area_enter'){
   // Entering a level can leave the native scheduler between decisions.
   // Record every bounded continuation; never issue a rest or player action.
   for(let n=0;session.bridge.pending && n<100;n++){
    const step=await session.execute('command',{type:'continue_pending',revision:session.bridge.revision});
    if(step.status!==200)throw Error('new level scheduler failed');
   }
   if(session.bridge.pending)throw Error('new level scheduler did not settle');
  }
 }
 return results;
}
export async function validateOperations(session,kernel,request){
 const results=await executeNativeOperations(session,kernel,request);
 let archive;
 const readOnly=(request.operations || []).length>0 && request.operations.every(op=>op.operation==='scene_query');
 const stoppedNative=request.native_checkpoints===true && session.bridge.boundary==='decision' && session.bridge.snapshot?.ai_status==='stopped' && !session.bridge.locked && !session.bridge.pending && !session.bridge.authorized && !session.bridge.navigation && !session.bridge.snapshot?.input_request;
 if(readOnly){session.suspended=true;archive=request.archive;}
 else if((request.operations || []).length && !stoppedNative)archive=await session.suspend();
 else{session.suspended=true;archive=await session.archive();}
 if(!readOnly && request.native_checkpoints===true && session.bridge.boundary==='decision')archive=await session.checkpoint();
 const native=await kernel.rpc('dm_inspect',{},session.bridge.generation);
 return {ok:true,archive,view:session.bridge.state(),native,results};
}
