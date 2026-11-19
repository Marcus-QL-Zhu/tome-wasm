const COMMANDS = ['move','navigate_start','navigate_step','wait','melee','ranged','talent','use_item','ai_step','pause','new_game','takeover','return_control','native_control','rescue_start','rescue_step','rescue_cancel','confirm_down','input_response'];
const integer = Number.isInteger;
class Rejected extends Error {}
export function validateObservation(s,generation,boundary) {
 const object=x=>x!==null && typeof x==='object' && !Array.isArray(x);
 const actors=a=>Array.isArray(a) && a.every(x=>object(x) && (Number.isInteger(x.id)||typeof x.id==='string') && ['effects','resources','equipment'].every(k=>!Array.isArray(x[k]) || x[k].every(object)));
 const invalid=()=>{const e=Error('invalid observation');e.code='invalid_observation';throw e;};
 const marked=s && ('area_outside' in s || 'map_available' in s),outside=s?.area_outside===true && s?.map_available===false;
 if(marked && (typeof s.area_outside!=='boolean' || typeof s.map_available!=='boolean' || s.map_available===false && s.area_outside!==true))invalid();
 if(outside && (!['explored_map','visible_map','terrain_visuals','entities','enemies'].every(k=>Array.isArray(s[k]) && s[k].length===0) || s.input_request!=null || !['idle','stopped'].includes(s.ai_status) || s.navigation?.status==='running' || !object(s.capabilities) || Object.values(s.capabilities).some(v=>v!==false) || boundary!==undefined && boundary!=='decision'))invalid();
 if(!s || s.generation!==generation || !Array.isArray(s.map) || (outside ? s.map.length!==0 : !s.map.length || !s.map.every(r=>typeof r==='string' && r.length===s.map[0].length && r.length>0)) || !actors(s.party) || !s.party.length || !actors(s.enemies) || !Array.isArray(s.events) || !s.events.every(x=>typeof x==='string') || typeof s.status!=='string' || !Number.isFinite(s.turn) || s.turn<0 || (s.talents!==undefined && (!Array.isArray(s.talents)||!s.talents.every(object))))invalid();
 if(s.rule_events!==undefined && (!Array.isArray(s.rule_events) || !s.rule_events.every(e=>object(e)&&Number.isInteger(e.id)&&e.id>0&&typeof e.kind==='string'&&['pending','done','cancelled'].includes(e.phase)&&Number.isFinite(e.turn)&&Number.isInteger(e.x)&&Number.isInteger(e.y))))invalid();
 if(s.controlled_actor!==undefined && (!actors([s.controlled_actor]) || s.controlled_actor.id!==s.control_actor_id))invalid();
 if(s.control_targets!==undefined && (!actors(s.control_targets) || !s.control_targets.every(a=>typeof a.name==='string')))invalid();
 if(s.control_change!=null && (!object(s.control_change) || !Number.isInteger(s.control_change.serial) || s.control_change.serial<1 || s.control_change.current!==s.control_actor_id))invalid();
 const ended=['victory','defeat'].includes(s.status);
 if((s.status==='victory' && s.mission_complete!==true) || (ended && !outside && boundary!==undefined && boundary!=='terminal') || (ended && outside && s.campaign_withdrawn!==true) || (boundary==='terminal' && !ended) || (s.status==='pending_rescue' && (s.mission_complete!==true || !s.party.some(p=>p.down))))invalid();
}
export class EngineBridge {
  constructor(request) { this.rpc=request; this.revision=0; this.epoch=0; this.generation=null; this.boundary='decision'; this.pending=false; this.aiEpoch=null; this.authorized=false; this.navigation=false; this.remaining=0; this.reason=null; this.budgetStopPending=false; this.continuous=false; this.deferredUserStop=false; this.locked=false; this.snapshot=null; }
  async init(seed=7) {
    try {
      this.caps=await this.rpc('capabilities',{});
      if(this.caps?.protocol !== 'tome-headless-v1') throw Error('incompatible protocol');
      const r=await this.rpc('create',{seed,fixture:'formal'}); this.setGeneration(r); this.receipt(r); await this.observe();
      return this.state();
    } catch(e) {this.locked=true; throw e;}
  }
  setGeneration(r) { if(r?.accepted!==true || !integer(r.generation) || r.generation<0) throw Error('invalid generation'); this.generation=r.generation; }
  receipt(r) { if(r?.accepted!==true || r.generation!==this.generation || !['decision','input','await_input','terminal','pending'].includes(r.boundary)) throw Error('invalid receipt'); this.boundary=r.boundary; this.pending=r.boundary==='pending'; this.input=r.input_request; if('ai_epoch' in r) this.aiEpoch=r.ai_epoch; }
  async observe({confirmBudgetStop=false}={}) {
    let s=await this.rpc('observe',{},this.generation);
    validateObservation(s,this.generation,this.boundary);
    if(this.snapshot && this.snapshot.generation===s.generation && (this.snapshot.control_actor_id!==s.control_actor_id || this.snapshot.control_change?.serial!==s.control_change?.serial)){
      this.revoke();this.reason='control_changed';this.budgetStopPending=false;this.deferredUserStop=false;
    }
    if(confirmBudgetStop) {if(s.ai_status!=='stopped') throw Error('budget stop outcome unknown');this.budgetStopPending=false;}
    const outside=s.area_outside===true && s.map_available===false;
    const declared=this.caps.web_commands || {}, observed=s.capabilities || {}, methods=this.caps.methods || {};
    const caps=Object.fromEntries(COMMANDS.map(k=>[k,declared[k]===true && observed[k]===true]));
    caps.ai_step &&= this.caps.ai_provider==='player_aioo_custom';
    caps.ai_start=declared.ai_start===true && observed.ai_start===true && this.caps.ai_provider==='player_aioo_custom' && this.boundary==='decision' && !this.budgetStopPending;
    caps.ai_modes=Array.isArray(this.caps.ai_modes) ? this.caps.ai_modes.filter(m=>['sweep','explore','rest'].includes(m)) : ['sweep'];
    caps.ai_continuous=true;
    caps.ai_config=declared.ai_config===true && this.boundary==='decision' && (observed.ai_config===true || s.ai_status==='running');
    caps.pause=!outside && methods.observe===true; caps.save=false; caps.load=false; caps.ai_template_save=false; caps.ai_template_load=false;
    caps.continue_pending=this.pending && methods.advance===true;
    if(['pending','input','await_input','terminal'].includes(this.boundary)) for(const k of ['move','navigate_start','navigate_step','wait','melee','ranged','talent','use_item','ai_step','native_control']) caps[k]=false;
    if(this.authorized && ('ai_epoch' in s) && s.ai_epoch!==this.authorizedAiEpoch) {this.revoke();this.reason='native_stop';}
    if ('ai_epoch' in s) this.aiEpoch=s.ai_epoch;
    this.snapshot={...s,scene_kind:s.fixture==='formal'?'formal':'engineering',capabilities:caps,advance_status:this.boundary};
    if(['input','await_input'].includes(this.boundary) && this.input != null) this.snapshot.input_request=this.input;
  }
  state() { if(this.locked || !this.snapshot) return {...(this.snapshot || {}),online:false,stale:true,last_confirmed_status:this.snapshot?.status,status:'unknown',message:'内核结果未知；显示最后已确认的旧状态，所有操作已锁止',revision:this.revision,control_epoch:this.epoch,ai_status:'stopped',ai_remaining:0,capabilities:{}}; return {...this.snapshot,capabilities:{...this.snapshot.capabilities,ai_renew:this.authorized && this.continuous && this.remaining===0 && this.boundary==='decision' && this.snapshot.ai_status==='running' && this.snapshot.capabilities.ai_step===true && !this.snapshot.down_events?.length && !this.snapshot.rescue_progress && !this.snapshot.mission_complete && !['pending_rescue','victory','defeat','danger','blocked_danger'].includes(this.snapshot.status) && !['pending_rescue','victory','defeat','danger','blocked_danger'].includes(this.snapshot.pause_reason) && this.aiEpoch===this.authorizedAiEpoch},revision:this.revision,control_epoch:this.epoch,ai_remaining:this.remaining,ai_control_reason:this.reason}; }
  revoke() {this.continuous=false;this.authorized=false; this.navigation=false; this.remaining=0; this.epoch++;}
  async act(p) {this.receipt(await this.rpc('act',p,this.generation));}
  async stop(reason='user') { if(this.caps.methods?.ai_stop===true && !['terminal','await_input'].includes(this.boundary) && !this.pending && !this.snapshot.rescue_progress && !this.snapshot.down_events?.length && !this.snapshot.input_request) {await this.act({type:'ai_stop',reason}); if(this.boundary!=='decision') throw Error('stop outcome unknown');} }
  async drain() {for(let n=0;this.pending && n<3 && this.caps.methods?.advance===true;n++) this.receipt(await this.rpc('advance',{budget:100},this.generation));}
  async command(d) {
    const reply=(status,body)=>({status,body});
    if(!d || typeof d!=='object' || !integer(d.revision)) return reply(400,{error:'invalid body'});
    const type=d.type, meta=()=>({revision:this.revision,control_epoch:this.epoch});
    if(this.locked) return reply(500,{error:'内核状态未知',...meta()});
    if(type!=='pause' && d.revision!==this.revision) return reply(409,{error:'stale revision',...meta()});
    if((type==='ai_step' && (!this.authorized || this.remaining<=0)) || (type==='ai_renew' && !this.authorized)||(type==='navigate_step' && !this.navigation)||(['ai_step','ai_renew','navigate_step','rescue_step'].includes(type) && (!integer(d.control_epoch)||d.control_epoch!==this.epoch))) return reply(409,{error:'stale control epoch',...meta()});
    if(this.budgetStopPending && this.pending && type==='pause') {this.revoke();this.reason='budget_exhausted';this.revision++;return reply(200,this.state());}
    if(this.budgetStopPending && this.pending && type!=='continue_pending') return reply(409,{error:'pending budget completion',...meta()});
    if(['ai_start','ai_renew'].includes(type) && (!integer(d.budget)||d.budget<1||d.budget>500 || Object.keys(d).some(k=>!(type==='ai_start'?['type','revision','budget','mode','continuous']:['type','revision','control_epoch','budget']).includes(k)) || (type==='ai_start' && (('continuous' in d && typeof d.continuous!=='boolean') || !this.snapshot.capabilities.ai_modes.includes(d.mode ?? 'sweep'))))) return reply(400,{error:'AI budget must be an integer from 1 to 500',...meta()});
    const p={...d}; delete p.revision; delete p.control_epoch; delete p.budget; delete p.continuous;
    const cap=type==='attack'?p.mode:type;
    if((type==='attack' && !['melee','ranged'].includes(cap)) || ['melee','ranged'].includes(type) || this.state().capabilities?.[cap]!==true) return reply(403,{error:'unsupported command',...meta()});
    try {
      this.validate(p);
      if(type==='pause' && this.pending && this.authorized) this.deferredUserStop=true;
      if(!['ai_step','ai_renew','rescue_step','navigate_step'].includes(type) && !(type==='continue_pending' && this.continuous && this.authorized)) {this.revoke(); this.reason=null;}
      if(type==='ai_renew') {this.remaining=d.budget;this.reason=null;this.revision++;return reply(200,this.state());}
      if(type==='pause') {await this.stop(); this.reason='user_pause';}
      else if(type==='continue_pending') await this.drain();
      else if(type==='new_game') {const r=await this.rpc('reset',{seed:p.seed??7},this.generation); const old=this.generation; this.setGeneration(r); if(this.generation<=old) throw Error('invalid reset'); this.receipt(r); this.budgetStopPending=false;}
      else {
        if(!['ai_step','ai_start','navigate_step','input_response'].includes(type) && !this.snapshot.rescue_progress && !this.snapshot.down_events?.length) await this.stop();
        let native=type==='ai_step'?{type:'native_ai',ai_epoch:this.aiEpoch}:type==='ai_config'?{type:'ai_config',config:Object.fromEntries(Object.entries(p).filter(([k])=>k!=='type'))}:p;
        if(type==='input_response'){delete native.type;this.receipt(await this.rpc('respond_input',native,this.generation));}else await this.act(native); if(type!=='confirm_down') await this.drain();
      }
      await this.observe();
      if(this.snapshot.down_events?.length && type==='rescue_step') {this.revoke();this.reason='party_down';}
      if(type==='navigate_start' && this.snapshot.navigation?.status==='running') this.navigation=true;
      if(type==='navigate_step' && this.snapshot.navigation?.status!=='running') {this.navigation=false;this.epoch++;}
      if(type==='ai_start' && this.snapshot.ai_status==='running') {this.authorized=true;this.authorizedAiEpoch=this.aiEpoch;this.continuous=d.continuous===true;this.remaining=d.budget;}
      if(type==='ai_step' && this.reason!=='control_changed') {
        this.remaining--;
        if(!this.authorized || this.snapshot.ai_status!=='running'||['input','await_input','terminal'].includes(this.boundary) || this.snapshot.down_events?.length || this.snapshot.rescue_progress || this.snapshot.mission_complete || ['pending_rescue','victory','defeat','danger','blocked_danger'].includes(this.snapshot.status)) {this.revoke();this.reason='native_stop';}
        else if(this.remaining===0) {if(this.continuous) this.reason='budget_boundary'; else {this.revoke();this.budgetStopPending=true;this.reason='budget_exhausted';}}
      }
      if(type==='continue_pending' && this.authorized && (this.snapshot.ai_status!=='running' || ['input','await_input','terminal'].includes(this.boundary) || this.snapshot.down_events?.length || this.snapshot.rescue_progress || this.snapshot.mission_complete || ['pending_rescue','victory','defeat','danger','blocked_danger'].includes(this.snapshot.status))) {this.revoke();this.reason='native_stop';}
      if(type==='continue_pending' && this.deferredUserStop && !this.pending) {
        this.deferredUserStop=false;
        const safe=this.boundary==='decision' && this.snapshot.ai_status==='running' && !this.snapshot.down_events?.length && !this.snapshot.rescue_progress && !this.snapshot.mission_complete && !this.snapshot.ai_alert?.length && !['pending_rescue','victory','defeat','danger','blocked_danger','party_critical'].includes(this.snapshot.status) && !['pending_rescue','victory','defeat','danger','blocked_danger','party_critical'].includes(this.snapshot.pause_reason);
        if(safe) {await this.stop('user');await this.observe();this.reason='user_pause';}
      }
      if(this.budgetStopPending) {
        this.reason='budget_exhausted';
        if(this.boundary==='decision' && !this.snapshot.down_events?.length && !this.snapshot.rescue_progress) {
          await this.stop('budget'); await this.observe({confirmBudgetStop:true});
        }
      }
      this.revision++;return reply(200,this.state());
    } catch(e) {this.revoke();this.revision++;if(e instanceof Rejected) return reply(400,{error:e.message,...meta()}); if(e?.outcome==='rejected') {try {await this.observe(); return reply(400,{error:e.message,...meta()});} catch (_) {}} this.locked=true;return reply(500,{error:'内核未确认操作结果；自动授权已撤销，内核状态未知',...meta()});}
  }
  validate(p) {
    const t=p.type, id=x=>(typeof x==='string'||integer(x)) && /^\d+$/.test(String(x));
    const keys=(...k)=>Object.keys(p).sort().join(',')===k.sort().join(',');
    if(t==='input_response' && (!integer(p.input_id)||p.input_id<1||Object.keys(p).some(k=>!['type','input_id','cancel','x','y','choice','value'].includes(k))||('cancel' in p && typeof p.cancel!=='boolean'))) throw new Rejected('invalid native input');
    if(t==='new_game' && (!integer(p.seed??7)||(p.seed??7)<0||(p.seed??7)>2147483647)) throw new Rejected('invalid seed');
    if(t==='move' && (!integer(p.dx)||!integer(p.dy)||Math.max(Math.abs(p.dx),Math.abs(p.dy))!==1)) throw new Rejected('invalid move');
    if(t==='navigate_start' && (!keys('type','x','y')||!integer(p.x)||!integer(p.y))) throw new Rejected('invalid navigation target');
    if(['navigate_step','return_control','rescue_step','rescue_cancel'].includes(t) && !keys('type')) throw new Rejected('unexpected parameters');
    if(['attack','takeover','rescue_start'].includes(t) && !id(p.target)) throw new Rejected('invalid target');
    if(t==='native_control' && (!keys('type','target') || !id(p.target)))throw new Rejected('invalid native control target');
    if(t==='talent' && (typeof p.talent!=='string'||!p.talent||p.talent.length>128 || (p.target!=null&&!id(p.target)) || (('x' in p||'y' in p) && (p.target!=null||!integer(p.x)||!integer(p.y))))) throw new Rejected('invalid talent');
    if(t==='use_item' && (!keys('type','actor_id','slot','pos','uid')||typeof p.actor_id!=='string'||!p.actor_id||typeof p.slot!=='string'||!p.slot||!integer(p.pos)||p.pos<1||!integer(p.uid)||p.uid<1))throw new Rejected('invalid inventory selection');
    if(t==='confirm_down' && (!keys('type','event_id','generation')||!integer(p.event_id)||p.event_id<1||p.generation!==this.generation)) throw new Rejected('invalid down event');
  }
}





