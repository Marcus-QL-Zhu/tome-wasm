(() => {
 const worker=new Worker('./browser_worker.mjs',{type:'module'}),pending=new Map();let seq=0,failed=false,initialized=false,lastConfirmed=null,firstFailure=null;
 let checkpointBusy=false,inventoryState=null;
 let battleId=new URL(location.href).searchParams.get('battle'),version=0,enabled=false,dirty=false,pendingSave=null;
 const history=[],metrics=document.createElement('output');metrics.id='wasm_metrics';metrics.style.cssText='display:block;font-size:.85em;opacity:.8';metrics.textContent='Wasm本地 · 等待初始化';document.querySelector('.map-hint')?.append(metrics);
 const feedback=document.createElement('span');feedback.id='checkpoint_status';feedback.setAttribute('role','status');document.querySelector('.map-hint')?.append(feedback);
 function fail(error){if(!firstFailure)firstFailure={reason:String(error?.message || error),last_confirmed:lastConfirmed,requests:[...history]};failed=true;for(const resolve of pending.values())resolve({status:500,body:{error:'Wasm 内核状态未知'}});pending.clear();window.dispatchEvent(new CustomEvent('tome-runtime-failed'));}
 worker.onmessage=({data})=>{if(Number.isFinite(data.timing?.initialization_ms))initialized=true;const resolve=pending.get(data.id);if(resolve){pending.delete(data.id);resolve(data);}};worker.onerror=fail;worker.onmessageerror=fail;
 async function raw(path,body){
  if(failed)return {status:500,body:{error:'Wasm 内核状态未知'}};
  return new Promise(resolve=>{const id=++seq;const timer=setTimeout(()=>{worker.terminate();fail('request_timeout');},path==='/api/bootstrap'?240000:60000);pending.set(id,value=>{clearTimeout(timer);resolve(value);});worker.postMessage({id,path,body});});
 }
 const boot=(async()=>{
  let config={};
  try{const c=await fetch('/api/session-capabilities',{cache:'no-store'});enabled=c.ok && (await c.json()).persistent_sessions===true;}catch{}
  if(battleId){
   if(!enabled)throw Error('当前服务不能恢复战局；没有创建新战局');
   const r=await fetch('/api/checkpoints/'+encodeURIComponent(battleId),{cache:'no-store'});if(!r.ok)throw Error('战局存档不存在或不可恢复');
   const saved=await r.json();version=saved.version;
   if(saved.state==='suspended'||saved.terminal_pending===true){location.replace('/dm.html?battle='+encodeURIComponent(battleId));throw Error('战局已交接，正在进入跑团交接页');}
   config={archive:saved.archive,suspended:false,combat_facts:saved.combat_facts};
   if(saved.archive?.format==='tome-partition-session-v1'){const p=await fetch('/api/partition-checkpoints/'+encodeURIComponent(battleId),{cache:'no-store'});if(!p.ok)throw Error('分区存档不可恢复');config.partition=await p.json();if(config.partition.version!==version)throw Error('存档版本已变化，请刷新');}
  }
  const r=await raw('/api/bootstrap',config);if(r.status!==200)throw Error(r.body.error);return r;
 })();
 function chooseLoot(items,coins=0){
  if(!items.length&&!coins)return Promise.resolve([]);
  return new Promise(resolve=>{
   const dialog=document.createElement('dialog');
   dialog.className='battle-loot';dialog.setAttribute('aria-label','离图战利品');
   const make=(tag,text)=>{const node=document.createElement(tag);if(text!==undefined)node.textContent=text;return node;};
   const close=value=>{window.campaignItemTooltip?.close();dialog.close();dialog.remove();resolve(value);};
   const title=make('h2','离图战利品'),list=make('table'),summary=make('p'),review=make('div'),actions=make('div');
   summary.setAttribute('aria-live','polite');
   const head=make('tr');for(const label of ['保留','图标','装备','转化金币'])head.append(make('th',label));list.append(head);
   const currency=cents=>((cents||0)/100).toLocaleString('zh-CN',{maximumFractionDigits:2});
   const update=()=>{
    const keep=choices.filter(x=>x.keep).length,cents=choices.reduce((n,x)=>n+(x.keep?0:x.transmo_cents),0);
    summary.textContent=items.length?`保留 ${keep} 项 · 转化 ${choices.length-keep} 项 · 获得 ${currency(cents+coins)} 金`:`拾取 ${currency(coins)} 金`;
   };
   const choices=items.map(item=>{
    const choice={uid:item.uid,count:item.count,transmo_cents:item.transmo_cents,keep:item.locked};
    const row=make('tr'),check=make('input');check.type='checkbox';check.checked=item.locked;check.disabled=item.locked;
    check.setAttribute('aria-label','保留 '+item.name);check.onchange=()=>{choice.keep=check.checked;update();};
    const pick=make('td'),art=make('td'),name=make('td'),price=make('td',item.transmo_cents===null?'—':currency(item.transmo_cents));
    pick.append(check);
    if(item.icon){const img=make('img');img.alt='';img.src='./assets/'+item.icon;img.loading='lazy';art.append(img);}
    const label=make('button',item.name+(item.relic?' · 遗物':''));label.type='button';label.className='battle-loot-name';
    if(item.relic)label.classList.add('battle-loot-relic');
    else if(/^#[0-9a-f]{6}$/i.test(item.color))label.style.color=item.color;
    name.append(label);
    const shared=window.campaignItemTooltip;
    if(shared){
     const details={name:item.name,description:item.description,relic_id:item.relic||undefined};
     shared.attach(art,details);shared.attach(label,details);
    }else{
     const tip=make('div',item.description||'暂无详情。');tip.className='battle-loot-tip';tip.hidden=true;
     let pinned=false;
     const show=()=>{tip.hidden=false;};
     const hide=()=>{tip.hidden=!pinned;};
     for(const target of [art,label]){
      target.addEventListener('pointerenter',show);target.addEventListener('pointerleave',hide);
     }
     label.onfocus=show;label.onblur=hide;
     label.onclick=()=>{pinned=!pinned;tip.hidden=!pinned;};
     name.append(tip);
    }
    row.append(pick,art,name,price);list.append(row);
    return choice;
   });
   const primary=make('button','转化并关闭'),cancel=make('button','返回战斗');
   const confirm=make('button',items.length?'确认转化':'确认返回'),back=make('button','返回');
   primary.onclick=()=>{window.campaignItemTooltip?.close();list.hidden=true;actions.hidden=true;review.hidden=false;back.focus();};
   cancel.onclick=()=>close(null);
   back.onclick=()=>{review.hidden=true;actions.hidden=false;list.hidden=false;primary.focus();};
   confirm.onclick=()=>close(choices);
   review.hidden=true;review.append(make('p','按上述选择结算并返回跑团？'),confirm,back);
   actions.append(primary,cancel);
   dialog.oncancel=event=>{event.preventDefault();if(!review.hidden)back.click();else close(null);};
   update();dialog.append(title,...(items.length?[list]:[]),summary,actions,review);document.body.append(dialog);dialog.showModal();
  });
 }
 window.tomeTransport={request:async(url,options={})=>{
  let result;
  try{await boot;let body;if(options.body)body=JSON.parse(options.body);
   if(!['/api/state','/api/command','/api/diagnostics','/api/inspect'].includes(url))result={status:404,body:{error:'unknown path'}};
   else{
    if(url==='/api/command'){history.push(body);if(history.length>128)history.shift();}
    const hot=initialized,began=performance.now();result=await raw(url,body);
    if(url==='/api/command' && result.status===200){dirty=true;feedback.textContent=' · 有未保存行动';}
    if(url==='/api/command' && result.status===200 && enabled && result.body?.campaign_bound!==true && ['victory','defeat'].includes(result.body?.status)){
     try{await window.tomeTransport.checkpoint(false);}
     catch(e){feedback.textContent=' · 终局尚未保存：'+e.message+'；请重试保存';}
    }
    if(hot && url==='/api/command' && result.status===200 && Number.isFinite(result.timing?.engine_ms))metrics.textContent=`Wasm本地 · Worker处理${result.timing.engine_ms.toFixed(1)}ms · 往返${(performance.now()-began).toFixed(1)}ms`;
   }
  }catch(e){result={status:500,body:{error:e.message}};}
  if(result.status===200 && Array.isArray(result.body?.map) && !result.body.stale){lastConfirmed=result.body;inventoryState=result.body;renderInventory();}
  return {ok:result.status>=200 && result.status<300,status:result.status,json:async()=>result.body};
 },exportDiagnostics:async()=>{
  const response=await raw('/api/diagnostics');const data=response.status===200?response.body:firstFailure;
  const url=URL.createObjectURL(new Blob([JSON.stringify(data,null,2)],{type:'application/json'}));const a=document.createElement('a');a.href=url;a.download='tome-diagnostics-'+Date.now()+'.json';a.click();setTimeout(()=>URL.revokeObjectURL(url),1000);
 },checkpoint:async handover=>{
  if(handover&&lastConfirmed?.temporary_plane)throw Error('请先返回原战场。当前可以保存战局。');
  await boot;if(!enabled)throw Error('当前服务未启用持久存档');
  window.dispatchEvent(new CustomEvent('tome-stop-automation'));
  feedback.textContent=' · 正在暂停并保存完整战局…';
  if(!pendingSave){
   let lootChoices;
   if(handover&&lastConfirmed?.campaign_bound&&lastConfirmed.status!=='defeat'){
    feedback.textContent=' · 正在查看可取得的战利品…';
    const preview=await raw('/api/loot_preview');
    if(preview.status!==200 || preview.body.available){
     if(preview.status===200){
      window.dispatchEvent(new CustomEvent('tome-session-state',{detail:preview.body.view}));
      lootChoices=await chooseLoot(preview.body.items,preview.body.coin_cents);
     }
     if(preview.status!==200||lootChoices===null){
      const resumed=await raw('/api/continue_session');
      if(resumed.status!==200)throw Error('本地战局未恢复');
      window.dispatchEvent(new CustomEvent('tome-session-state',{detail:resumed.body}));
      if(preview.status!==200)throw Error(preview.body.error||'战利品暂不可读');
      feedback.textContent='';
      window.dispatchEvent(new Event('tome-handover-cancelled'));
      return null;
     }
    }
   }
   feedback.textContent=' · 正在保存完整战局…';
   const r=await raw('/api/export_save');if(r.status!==200)throw Error(r.body.error);
   window.dispatchEvent(new CustomEvent('tome-session-state',{detail:r.body.view}));
   pendingSave={request_id:crypto.randomUUID(),version,archive:r.body.archive,handover};if(battleId)pendingSave.battle_id=battleId;
   if(lootChoices!==undefined)pendingSave.loot_choices=lootChoices;
   if(r.body.snapshot)pendingSave.snapshot=r.body.snapshot;
  }
  if(pendingSave.handover!==handover)throw Error('请先重试上一次保存请求');
  const response=await fetch('/api/checkpoints',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(pendingSave)});
  const receipt=await response.json();if(!response.ok)throw Error(receipt.error || '服务器未确认存档');
  if(receipt.loot_pending||receipt.terminal_pending){
   if(typeof window.campaignLootStatus!=='function')throw Error('战利品结算状态暂不可读');
   feedback.textContent=receipt.terminal_pending?' · 正在结算小队战败…':' · 正在登记战利品和金币…';
   let settled;
   for(let i=0;i<30;i++){
    settled=await window.campaignLootStatus();
    if(settled.status==='synced')break;
    await new Promise(resolve=>setTimeout(resolve,500));
   }
   if(settled?.status!=='synced'||settled.battle_id!==receipt.battle_id
      ||!Number.isInteger(settled.version)||settled.version<receipt.version)throw Error('战局尚待结算');
   receipt.version=settled.version;
   window.dispatchEvent(new CustomEvent('tome-loot-handover-complete',{detail:receipt}));
  }
  battleId=receipt.battle_id;version=receipt.version;pendingSave=null;dirty=false;
  window.history.replaceState(null,'','/?battle='+encodeURIComponent(battleId));feedback.textContent=' · 战局已保存';
  if(handover){location.assign('/dm.html?battle='+encodeURIComponent(battleId));return receipt;}
  if(receipt.native_checkpoint===true || receipt.partition_checkpoint===true){
  const savedResponse=await fetch('/api/checkpoints/'+encodeURIComponent(battleId),{cache:'no-store'});
  if(!savedResponse.ok)throw Error('服务器已保存，但本地基线未更新；请刷新恢复');
  const saved=await savedResponse.json();
  if(saved.version!==version)throw Error('服务器存档版本已变化；请刷新恢复');
  if(['tome-native-session-v1','tome-partition-session-v1'].includes(saved.archive?.format)){
   let partition;
   if(saved.archive.format==='tome-partition-session-v1'){
    const response=await fetch('/api/partition-checkpoints/'+encodeURIComponent(battleId),{cache:'no-store'});
    if(!response.ok)throw Error('服务器已保存，但分区基线未更新；请保留页面');
    partition=await response.json();
   }
   const adopted=await raw('/api/adopt_checkpoint',{archive:saved.archive,partition});
   if(adopted.status!==200)throw Error('服务器已保存，但本地基线未更新；请刷新恢复');
  }
  }
  const continued=await raw('/api/continue_session');if(continued.status!==200)throw Error('本地战局未恢复');
  window.dispatchEvent(new CustomEvent('tome-session-state',{detail:continued.body}));return receipt;
 }};
 const controls=document.querySelector('header .mode');
 const inventorySelect=document.createElement('select'),inventoryUse=document.createElement('button');
 inventorySelect.setAttribute('aria-label','选择物品');inventoryUse.textContent='使用物品';inventoryUse.disabled=true;controls?.append(inventorySelect,inventoryUse);
 function renderInventory(){
  inventorySelect.replaceChildren();const prompt=document.createElement('option');prompt.value='';prompt.textContent='选择物品';inventorySelect.append(prompt);
  for(const [index,item] of (inventoryState?.inventory || []).entries()){const option=document.createElement('option');option.value=String(index);option.textContent=item.name+' · '+item.slot;inventorySelect.append(option);}
  inventoryUse.disabled=inventoryState?.capabilities?.use_item!==true;
 }
 inventoryUse.onclick=async()=>{
  const index=inventorySelect.value;if(index==='' || !inventoryState?.inventory?.[Number(index)])return;
  const selected=inventoryState.inventory[Number(index)],revision=inventoryState.revision;
  inventoryUse.disabled=true;
  window.dispatchEvent(new CustomEvent('tome-stop-automation'));
  let response=await window.tomeTransport.request('/api/command',{body:JSON.stringify({type:'use_item',actor_id:selected.actor_id,slot:selected.slot,pos:selected.pos,uid:selected.uid,revision})});
  let value=await response.json();
  for(let n=0;response.ok && value.advance_status==='pending' && n<100;n++){
   response=await window.tomeTransport.request('/api/command',{body:JSON.stringify({type:'continue_pending',revision:value.revision})});value=await response.json();
  }
  if(response.ok)window.dispatchEvent(new CustomEvent('tome-session-state',{detail:value}));else feedback.textContent=' · '+(value.error || '物品使用未完成');
 };
 renderInventory();
 for(const [id,text,handover] of [['save_battle','保存战局',false],['to_dm','转为跑团',true]]){
  const button=document.createElement('button');button.id=id;button.textContent=text;button.disabled=true;controls?.append(button);
  boot.then(()=>{button.disabled=!enabled;}).catch(()=>{});
  button.onclick=async()=>{if(checkpointBusy)return;checkpointBusy=true;for(const el of controls.querySelectorAll('#save_battle,#to_dm'))el.disabled=true;try{await window.tomeTransport.checkpoint(handover);}catch(e){feedback.textContent=' · '+e.message+'；当前页面保留，请重试保存';}finally{checkpointBusy=false;for(const el of controls.querySelectorAll('#save_battle,#to_dm'))el.disabled=false;}};
 }
 window.addEventListener('beforeunload',e=>{if(dirty || pendingSave){e.preventDefault();e.returnValue='';}});
})();
