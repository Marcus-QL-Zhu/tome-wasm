// Disposable local character rules. Never uploads a native graph or saves a battle.
import createTome from './tome.js';
import {createKernel} from './kernel_runtime.mjs';
import {BattleSession} from './battle_session.mjs';
import {restorePartitionCandidate} from './partition_session.mjs';
import {selectPartitions} from './partition_transport.mjs';
let kernel,session,world,queue=Promise.resolve();
self.onmessage=({data})=>{queue=queue.then(async()=>{
 try{
  let result;
  if(data.method==='init'){
   kernel=await createKernel(createTome);const {archive,partition}=data;
   if(archive.build!=='__TOME_BUILD_ID__')throw Error('人物规则版本不匹配');
   if(archive.format==='tome-partition-session-v1'){
    const m=partition.manifest,scope={build:archive.build,world_id:m.world_id,campaign_id:m.campaign_id};
    if(partition.version!==archive.base.version)throw Error('人物状态已更新，请重开界面');
    const ids=selectPartitions(m,scope,{kind:'loadout'});
    if(ids.length!==1||ids[0]!=='hot')throw Error('人物编辑只允许当前人物片');
    session=await restorePartitionCandidate(kernel.rpc,archive.build,archive.seed,scope,archive.base.envelope,m,ids,partition.blobs);world=m.world_id;
   }else{session=await BattleSession.restore(kernel.rpc,archive.build,archive);}
   result={ready:true};
  }else if(data.method==='inspect'){
   if(!session)throw Error('人物规则尚未加载');
   result=await kernel.rpc('dm_inspect',{},session.bridge.generation);
  }else{
   if(!session)throw Error('人物规则尚未加载');
   result=await kernel.rpc('character_editor',data.params,session.bridge.generation);
  }
  self.postMessage({id:data.id,ok:true,result});
 }catch(e){self.postMessage({id:data.id,ok:false,error:String(e.message||e)});}
});};
