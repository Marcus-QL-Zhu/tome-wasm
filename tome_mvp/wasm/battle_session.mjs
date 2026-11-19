import {EngineBridge} from './engine_bridge.mjs';

export function canonical(value){
 if(value===null || typeof value!=='object')return JSON.stringify(value);
 if(Array.isArray(value))return '['+value.map(canonical).join(',')+']';
 return '{'+Object.keys(value).filter(k=>value[k]!==undefined).sort().map(k=>JSON.stringify(k)+':'+canonical(value[k])).join(',')+'}';
}
export async function digest(value){
 const bytes=new TextEncoder().encode(canonical(value));
 return Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256',bytes)),x=>x.toString(16).padStart(2,'0')).join('');
}
// A complete, untruncated deterministic reconstruction log. The 128-entry crash
// diagnostic is separate. Every native call caused by these events is repeated.
export class BattleSession {
 constructor(rpc,build,seed){this.bridge=new EngineBridge(rpc);this.build=build;this.seed=seed;this.events=[];this.initial=null;this.suspended=false;this.rulePhases=new Map();this.nativeBase=null;this.audit=[];}
 async init(){const s=await this.bridge.init(this.seed);this.initial=await digest(s);for(const event of s.rule_events || [])this.rulePhases.set(s.generation+':'+event.id,event.phase);return s;}
 async execute(kind,body){
  if(this.suspended)throw Error('battle is suspended');
  if(this.events.length>=200000)throw Error('session journal capacity reached');
  let result;
  if(kind==='command')result=await this.bridge.command(body);
  else if(kind==='inspect'){
   try{result={status:200,body:await this.bridge.rpc('inspect_actor',body,this.bridge.generation)};}
   catch(e){if(e.outcome!=='rejected')throw e;result={status:400,body:{error:e.message}};}
  }else if(kind==='dm_transition' || kind==='campaign_next' || kind==='campaign_items' || kind==='campaign_adopt' || kind==='campaign_reconcile' || kind==='campaign_settle' || kind==='campaign_wipeout'){
   const r=await this.bridge.rpc(kind,body,this.bridge.generation);
   this.bridge.receipt(r);
   await this.bridge.observe();this.bridge.revision++;result={status:200,body:this.bridge.state(),transition:r};
  }else throw Error('unknown session event');
  const event={kind,body:structuredClone(body),digest:await digest(result)},changes=[];
  if(result.status===200)for(const rule of result.body?.rule_events || []){
   const key=result.body.generation+':'+rule.id;
   if(this.rulePhases.get(key)!==rule.phase){changes.push(structuredClone(rule));this.rulePhases.set(key,rule.phase);}
  }
  if(changes.length)event.rule_events=changes;
  this.events.push(event);
  return result;
 }
 async suspend(){await this.settle();return this.archive();}
 async settle(){
  if(this.suspended)return;
  // Export never advances an unfinished action or its rule callbacks.
  if(this.bridge.pending)throw Error('battle is still settling; wait for a confirmed boundary before saving');
  if(this.partitionOnly && this.bridge.boundary==='terminal'){
   const b=this.bridge;
   if(b.locked || b.authorized || b.navigation || b.snapshot?.input_request)throw Error('terminal save is not at a confirmed boundary');
   for(let batch=0;batch<16;batch++){
    const result=await b.rpc('campaign_settle',{},b.generation);
    b.receipt(result);
    if(result.transition?.remaining===false){
     await b.observe();
     if(b.pending || b.snapshot?.input_request)throw Error('terminal action requires input');
     this.suspended=true;return;
    }
   }
   throw Error('terminal callbacks did not settle');
  }
  if(this.bridge.boundary==='terminal' || (this.bridge.snapshot?.area_outside===true && this.bridge.snapshot?.map_available===false)){
   if(this.bridge.locked || this.bridge.pending || this.bridge.authorized || this.bridge.navigation)throw Error('save is not at a confirmed boundary');
   this.suspended=true;return;
  }
  if(this.bridge.snapshot?.input_request){
   if(this.bridge.locked || this.bridge.pending || this.bridge.authorized || this.bridge.navigation)throw Error('input is not at a confirmed boundary');
   // Saving never makes a skill choice or cancels a partially executed talent.
   this.suspended=true;return;
  }
  const r=await this.execute('command',{type:'pause',revision:this.bridge.revision});
  if(r.status!==200)throw Error('pause was not confirmed');
  for(let i=0;this.bridge.pending && i<100;i++){
   const settled=await this.execute('command',{type:'continue_pending',revision:this.bridge.revision});
   if(settled.status!==200)throw Error('action settlement failed');
  }
  if(this.bridge.pending || this.bridge.locked || this.bridge.authorized || this.bridge.navigation)throw Error('battle is not at a confirmed boundary');
  this.suspended=true;
 }
 async archive(){
  if(this.bridge.locked || this.bridge.pending || !this.suspended)throw Error('no confirmed suspended state');
  if(this.partitionOnly){
   if(!this.partitionBase)throw Error('partition candidate requires authoritative host export');
   return {format:'tome-partition-session-v1',build:this.build,seed:this.seed,base:structuredClone(this.partitionBase),audit:structuredClone(this.audit),events:structuredClone(this.events),final:await digest(this.bridge.state())};
  }
  if(this.nativeBase)return {format:'tome-native-session-v1',build:this.build,seed:this.seed,base:structuredClone(this.nativeBase),audit:structuredClone(this.audit),events:structuredClone(this.events),final:await digest(this.bridge.state())};
  return {format:'tome-replay-save-v1',build:this.build,seed:this.seed,initial:this.initial,events:structuredClone(this.events),final:await digest(this.bridge.state())};
 }
 // Only the authoritative host may persist the result of this operation. A
 // client-provided base must never replace the host's stored checkpoint.
 async checkpoint(){
  if(!this.suspended || this.bridge.locked || this.bridge.pending || this.bridge.authorized || this.bridge.navigation || this.bridge.boundary!=='decision' || this.bridge.snapshot?.input_request)throw Error('native checkpoint requires a stopped decision boundary');
  const checkpoint=await this.bridge.rpc('snapshot_export',{},this.bridge.generation);
  if(checkpoint?.format!=='tome-native-save-v1' || typeof checkpoint.blob!=='string' || !checkpoint.blob || new TextEncoder().encode(checkpoint.blob).byteLength>64*1024*1024 || checkpoint.generation!==this.bridge.generation || checkpoint.boundary!=='decision')throw Error('invalid native checkpoint');
  const bridge={revision:this.bridge.revision,epoch:this.bridge.epoch,reason:this.bridge.reason};
  const base={checkpoint,bridge,final:await digest(this.bridge.state())};
  this.audit.push(...this.events.filter(e=>['dm_transition','campaign_next','campaign_items','campaign_adopt','campaign_reconcile','campaign_settle','campaign_wipeout'].includes(e.kind)).map(e=>structuredClone(e)));
  this.nativeBase=base;this.events=[];
  return this.archive();
 }
 static async restore(rpc,build,doc){
  if(doc?.format==='tome-native-session-v1'){
   if(doc.build!==build || !Number.isInteger(doc.seed) || doc.seed<0 || doc.seed>2147483647 || !Array.isArray(doc.events) || doc.events.length>200000 || !Array.isArray(doc.audit) || !doc.base || !doc.base.bridge || doc.base.checkpoint?.format!=='tome-native-save-v1' || (typeof doc.base.checkpoint.blob!=='string' || new TextEncoder().encode(doc.base.checkpoint.blob).byteLength>64*1024*1024))throw Error('incompatible native session');
   const session=new BattleSession(rpc,build,doc.seed),bridge=session.bridge,meta=doc.base.bridge;
   if(!Number.isSafeInteger(meta.revision) || meta.revision<0 || !Number.isSafeInteger(meta.epoch) || meta.epoch<0 || !(meta.reason===null || typeof meta.reason==='string'))throw Error('invalid bridge metadata');
   bridge.caps=await rpc('capabilities',{});
   if(bridge.caps?.protocol!=='tome-headless-v1')throw Error('incompatible protocol');
   const result=await rpc('snapshot_import',{format:doc.base.checkpoint.format,blob:doc.base.checkpoint.blob});
   if(result.generation!==doc.base.checkpoint.generation || result.boundary!=='decision')throw Error('native checkpoint mismatch');
   bridge.generation=result.generation;bridge.boundary=result.boundary;bridge.revision=meta.revision;bridge.epoch=meta.epoch;bridge.reason=meta.reason;
   await bridge.observe();
   if(await digest(bridge.state())!==doc.base.final)throw Error('native checkpoint state mismatch');
   session.nativeBase=structuredClone(doc.base);session.audit=structuredClone(doc.audit);
   for(const rule of bridge.snapshot?.rule_events || [])session.rulePhases.set(bridge.generation+':'+rule.id,rule.phase);
   for(const event of doc.events){
    await session.execute(event.kind,event.body);
    if(session.events.at(-1).digest!==event.digest || canonical(session.events.at(-1).rule_events || [])!==canonical(event.rule_events || []))throw Error('incremental replay diverged at event '+session.events.length);
   }
   if(bridge.locked || bridge.pending || bridge.authorized || bridge.navigation || await digest(bridge.state())!==doc.final)throw Error('restored state mismatch');
   return session;
  }
  if(!doc || doc.format!=='tome-replay-save-v1' || doc.build!==build || !Number.isInteger(doc.seed) || doc.seed<0 || doc.seed>2147483647 || !Array.isArray(doc.events) || doc.events.length>200000)throw Error('incompatible battle archive');
  const session=new BattleSession(rpc,build,doc.seed);await session.init();
  if(session.initial!==doc.initial)throw Error('initial state mismatch');
  for(const event of doc.events){
   await session.execute(event.kind,event.body);
   if(session.events.at(-1).digest!==event.digest || canonical(session.events.at(-1).rule_events || [])!==canonical(event.rule_events || []))throw Error('replay diverged at event '+session.events.length);
  }
  if(session.bridge.locked || session.bridge.pending || session.bridge.authorized || session.bridge.navigation || await digest(session.bridge.state())!==doc.final)throw Error('restored state mismatch');
  return session;
 }
}
