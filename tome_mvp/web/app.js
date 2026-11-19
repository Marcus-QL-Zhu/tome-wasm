"use strict";
let state = null, generation = 0, epoch = 0, queue = Promise.resolve(), gridAiming = false;
let targeting = null, inspectionToken=0;
const $ = id => document.getElementById(id);
const stateLabels = {active:"进行中",no_action:"没有可执行的动作",health_alert:"需要处理伤势",enemy_seen:"发现敌人",rested:"休息完成",party_critical:"队员重伤",awaiting_down_confirmation:"队员晕倒，等待确认",pending_rescue:"敌人已清剿，等待救援",paused:"已暂停",danger:"危急",blocked_danger:"危急停止",victory:"胜利",defeat:"失败",running:"运行中",idle:"待启动",stopped:"已停止",sweep:"扫荡",rest:"休息",explore:"探索",hunt:"追踪",fight:"战斗",budget_exhausted:"步数预算结束",user_stop:"玩家暂停",control_changed:"控制者已切换",input_required:"需要输入",native_input_required:"等待原生技能选择",native_input_resolved:"技能选择完成，等待继续",native_input_cancelled:"已取消技能选择",native_input_declined:"技能未生效，等待继续",native_input_interrupted:"技能后出现新危险",exploration_no_target:"没有可到达的探索目标",unclassified_dialog:"未识别的原生对话",ally_hp_at_or_below_25_percent_or_dead:"成员生命不高于 25% 或已死亡"};
function canStartNavigation(s){return s?.capabilities?.navigate_start === true;}
function sessionDuration(ms){if(typeof ms!=="number" || !Number.isFinite(ms) || ms<0)return "未知";const sec=Math.floor(ms/1000), hours=Math.floor(sec/3600), minutes=Math.floor(sec%3600/60);return hours ? `${hours}小时${minutes}分` : minutes ? `${minutes}分${sec%60}秒` : `${sec}秒`;}
function resourceCosts(values){const labels={mana:"法力",stamina:"体力",positive:"正能量",negative:"负能量",equilibrium:"失衡",paradox:"悖论",hate:"仇恨",vim:"活力",psi:"灵能",feedback:"反馈",steam:"蒸汽",souls:"灵魂"};return Object.entries(values||{}).map(([key,value])=>`${key.startsWith("sustain_")?"维持":""}${labels[key.replace(/^sustain_/,"")]||key} ${value}`).join("、")||"无";}
function label(value){return value == null ? "未知" : (stateLabels[value] ?? stateLabels[cleanLog(value)] ?? cleanLog(value));}
function terminalPresentation(s){
  const ended=['victory','defeat'].includes(s.status),bound=s.campaign_bound===true||s.campaign_withdrawn===true;
  const message=s.status==='victory'?'清剿完成：本场敌人已全部击败。':s.status==='defeat' && s.campaign_withdrawn===true?'团长已撤出。请返回佣兵团页面查看结算并继续跑团。':s.status==='defeat'?'本局结束：全队已倒地。':'';
  return {message,hideRestart:!ended||bound,hideNew:bound};
}
function talentReason(t){return ({cooldown:"冷却中",not_learned:"尚未学会",unknown_talent:"未知技能",content_policy:"当前内容尚未开放",unsupported_talent:"原生桥尚不支持",rule_callback_timing:"原生动画规则回调的时序尚未接入",passive:"被动技能",unavailable:"原生条件不满足"})[t.reason] ?? t.reason ?? "不可用";}
const addonLabels={"AI stop: Blind":"自动控制暂停：角色失明", "AI stop: Encumbered":"自动控制暂停：负重超限", "AI stop: Suffocating!":"自动控制暂停：角色窒息", "AI Stop: Low Health":"自动控制暂停：生命值过低", "AI stopped: Dialog displayed":"自动控制暂停：需要选择", "AI stopped: Rare or stronger enemy spotted!":"自动控制暂停：发现稀有或更强的敌人", "AI stopping: level change found":"自动控制暂停：发现楼层入口", "Player AIoo stop : cant choose talent nor flee":"自动控制暂停：无法选择技能或逃离", "Disabling Player AIoo!":"自动控制已关闭", "Player AIoo cannot be used in the wilderness!":"大地图上不能使用自动战斗", "AI cancelled by wilderness zone!":"已在大地图上停止自动控制", "AI Disabled. AI acted for 500 turns. Did it get stuck?":"自动控制已运行500回合，暂停以供检查"};
function cleanLog(value){const text=String(value).replace(/#(?:UID:[^#]*|[A-Za-z_]+|[0-9A-Fa-f]{6}|\{[A-Za-z_]+\})#/g, "");return addonLabels[text]??text.replace(/^AI stopped: (\d+) enemies spotted \(Limit: (\d+)\)!$/, '自动控制暂停：发现$1名敌人（上限$2）');}
function effects(actor){return Array.isArray(actor.effects) && actor.effects.length ? ` · 效果 ${actor.effects.map(e=>e.id === "EFF_MERCENARY_DOWN" ? "晕倒（等待救援）" : `${e.name ?? e.id ?? "未知"}（剩余 ${e.dur ?? "未知"}）`).join("、")}` : "";}
function hp(value){return typeof value === "number" && Number.isFinite(value) ? value.toFixed(1) : (value ?? "未知");}
function skillEnabled(t,caps){return caps?.talent === true && t?.available === true && ["self","hostile","grid","native"].includes(t?.target);}
function resourceDirection(r){return r?.switch_direction === true ? "lower" : null;}
function assetURL(path){
  if(typeof path!=="string" || !path.startsWith('data/gfx/') || !path.endsWith('.png') || /[\\:\x00]/.test(path) || path.split('/').some(part=>!part||part==='.'||part==='..')) return null;
  return "/assets/"+path.split("/").map(encodeURIComponent).join("/");
}
function controlledActor(s){return s?.controlled_actor || (s?.party || []).find(p=>p.id===s.control_actor_id);}
function visibleEnemy(e,s,cells){
  if(!Number.isInteger(e?.x)||!Number.isInteger(e?.y)||e.x<0||e.y<0)return false;
  if(Array.isArray(s.visible_map)) return s.visible_map[e.y]?.[e.x] === "1";
  return cells[e.y]?.[e.x] === "e";
}
function renderNativeInput(s){
 let box=$('native_input');
 if(!box){box=document.createElement('section');box.id='native_input';box.className='panel native-input';document.querySelector('.battlefield')?.append(box);}
 const input=s.input_request;box.hidden=!input;
 if(!input)return;
 const title=document.createElement('strong');title.textContent=cleanLog(input.prompt || '原生技能需要输入');
 const hint=document.createElement('p');hint.textContent=input.kind==='target'?'点击地图选择目标。Esc取消。':'选择一个原生选项。';
 const cancel=document.createElement('button');cancel.textContent='取消本次技能';cancel.onclick=()=>manual({type:'input_response',input_id:input.id,cancel:true});
 box.replaceChildren(title,hint,cancel);
 if(input.kind==='quantity'){
  const field=document.createElement('input');field.type='number';field.value=input.default ?? 0;field.setAttribute('aria-label','原生数值输入');if(input.min!=null)field.min=input.min;if(input.max!=null)field.max=input.max;
  const accept=document.createElement('button');accept.textContent='确认数值';accept.onclick=()=>manual({type:'input_response',input_id:input.id,value:Number(field.value)});box.append(field,accept);
 }
 for(const option of input.options || []){const button=document.createElement('button');button.textContent=cleanLog(option.label);button.onclick=()=>manual({type:'input_response',input_id:input.id,choice:option.id});box.append(button);}
}
function automationAlertText(s){
  const alerts=Array.isArray(s.ai_alert) ? s.ai_alert : [];
  return alerts.length ? alerts.map(a=>{
    const name=(s.party || []).find(p=>p.id===a.actor_id)?.name ?? String(a.actor_id ?? "未知队员");
    const percent=typeof a.hp==="number" && typeof a.max_hp==="number" && a.max_hp>0 ? `${(100*a.hp/a.max_hp).toFixed(1)}%` : "未知";
    const reason=a.kind==="threshold" ? `生命降至阈值 ${typeof a.percent==="number" ? `${a.percent}%` : "未知"}` : a.kind==="damage" ? `单步掉血 ${hp(a.loss)}` : "原生重伤警报";
    return `${name}：${reason}；当前生命 ${hp(a.hp)}/${hp(a.max_hp)}（${percent}）`;
  }).join("；")+"。再次启动仅确认本次重伤警报；倒地另行确认。" : "";
}
function automationShortcut(e){return !e.repeat && e.code==="KeyZ" ? "explore" : !e.repeat && e.code==="KeyR" ? "rest" : null;}
function freezeView(message){
  if(state?.stale)return;
  generation++; epoch++;
  display({...state,online:false,stale:true,status:'unknown',message:message || '内核结果未知；显示最后已确认的旧状态，操作已锁止',capabilities:{},ai_status:'stopped'});
}
function display(s) {
  if(targeting && (s.generation!==targeting.generation || s.control_actor_id!==targeting.actor || s.stale || ['victory','defeat'].includes(s.status))) {targeting=null;gridAiming=false;}
  state = s;
  if(typeof document.addEventListener==='function')renderNativeInput(s);
  const caps = s.capabilities || {};
  $("manual_mode").disabled=s.stale===true;
  const rulesSettled=s.last_action?.outcome==='rule_events_settled';
  const notice=$("runtime_notice"), ended=['victory','defeat'].includes(s.status);
  const outside=s.area_outside===true && s.map_available===false;
  notice.hidden=!s.stale && !ended && !rulesSettled && !outside;
  const terminalUI=terminalPresentation(s);
  $("runtime_message").textContent=s.stale ? '内核结果未知。下方是最后已确认的旧画面；操作已锁止。请先导出诊断，再重新载入。' : outside ? '已离开当前区域。请返回跑团继续。' : s.status==='defeat' && s.campaign_withdrawn===true ? terminalUI.message : rulesSettled ? '待处理的规则事件已结算。本次指令未执行，请按当前战场重新下令。' : terminalUI.message;
  $("export_diagnostics").hidden=!s.stale || typeof window==='undefined' || !window.tomeTransport?.exportDiagnostics;
  $("restart_after_end").hidden=terminalUI.hideRestart;
  $("new").hidden=terminalUI.hideNew;
  document.querySelectorAll("[data-move]").forEach(b=>{b.disabled=caps.move !== true;});
  document.querySelectorAll("[data-command]").forEach(b=>{b.disabled=caps[b.dataset.command] !== true; b.title=b.disabled ? "原生桥尚未支持此操作" : "";});
  for (const [id,cap] of [["melee","melee"],["ranged","ranged"],["auto","ai_start"],["pause","pause"],["new","new_game"]]) {$(id).disabled=caps[cap] !== true; $(id).title=$(id).disabled ? "当前不可用" : "";}
  for(const [id,mode] of [["explore","explore"],["rest","rest"]]) {$(id).disabled=caps.ai_start!==true || !caps.ai_modes?.includes(mode);}
  if(!(s.enemies || []).length){$("melee").disabled=true;$("melee").title="无可见目标";}
  else if(caps.melee!==true) $("melee").title=caps.melee===false?"当前无法近战":"近战状态未知";
  const rows = Array.isArray(s.map) ? s.map : (Array.isArray(s.map?.rows) ? s.map.rows : []);
  const cells = rows.map(row => Array.from(String(row)));
  for (const [index,p] of (s.party || []).slice(0,3).entries()) {
    if (Number.isInteger(p.x) && Number.isInteger(p.y) && p.y >= 0 && p.y < cells.length && p.x >= 0 && p.x < cells[p.y].length && cells[p.y][p.x] === "@") cells[p.y][p.x] = ["@","a","b"][index];
  }
  $("map").textContent = outside ? "已离开当前区域。" : cells.map(row=>row.join("")).join("\n");
  const dimensions = cells.length && cells.every(row => row.length === cells[0].length) ? `${cells[0].length}×${cells.length}` : "未知";
  const scene = s.scene_kind === "engineering" ? `工程场景 · 地图 ${dimensions} · ${(s.party || []).length}名队员 · 当前可见${(s.enemies || []).length}敌 · ` : "";
  $("status").textContent = `${s.online === false ? (s.message || "原生桥离线") + " · " : ""}${scene}回合 ${s.turn ?? "未知"} · 场次 ${s.generation ?? "未知"} · 状态 ${label(s.status)}${s.advance_status === "pending" ? " · 动作尚未到达决策边界" : (["input","await_input"].includes(s.advance_status) ? (s.down_events?.length ? " · 等待确认晕倒事件" : ` · 需要输入 ${label(s.input_request?.kind)}`) : "")}${s.pause_reason ? ` · 暂停原因 ${label(s.pause_reason)}` : ""} · AI ${label(s.ai_status)}${s.ai_mode ? ` · 模式 ${label(s.ai_mode)}` : ""}${s.ai_phase ? ` · 阶段 ${label(s.ai_phase)}` : ""}${s.ai_stop_reason ? ` · 停止原因 ${cleanLog(label(s.ai_stop_reason))}` : ""}${s.ai_control_reason === "budget_exhausted" ? " · 步数预算结束，已暂停" : ""} · 版本 ${s.revision}`;
  const nav=s.navigation;
  if(s.last_action?.outcome==='native_declined') $('status').textContent+=s.last_action.energy_spent ? ' · 技能未施放；原生规则已消耗行动时间' : ' · 技能未施放；本次未消耗行动时间';
  $("navigation_status").textContent=nav ? `路径状态：${label(nav.status)}${Number.isInteger(nav.x) && Number.isInteger(nav.y) ? ` · 目的地 ${nav.x}, ${nav.y}` : ""}${nav.stop_reason ? ` · 原因 ${label(nav.stop_reason)}` : ""}` : "点击移动：当前不可用";
  $("status").title = `会话已运行 ${sessionDuration(s.elapsed_ms)}（墙钟时间）；status: ${s.status ?? ""}; pause_reason: ${s.pause_reason ?? ""}`;
  $("party").replaceChildren(...(s.party || []).map((p,i) => {const d=document.createElement("div");d.textContent=`${["@","a","b"][i] ?? ""} ${p.name ?? "未知"}${p.down === true ? "（晕倒）" : (p.dead === true ? "（死亡）" : "")}${p.id === s.control_actor_id ? "（当前控制）" : ""}${p.id === s.leader_id ? "（团长）" : ""} · 生命 ${typeof p.hp === "object" ? JSON.stringify(p.hp) : hp(p.hp)}${p.max_hp != null ? `/${hp(p.max_hp)}` : ""} · 装备 ${typeof p.equipment === "object" ? JSON.stringify(p.equipment) : (p.equipment ?? "未知")}${effects(p)}`;return d;}));
  const alertBox=$("automation_alert");
  alertBox.textContent=automationAlertText(s);
  alertBox.hidden=!alertBox.textContent;
  const pendingDown=Array.isArray(s.down_events) ? s.down_events : [];
  $("down_notice").textContent=pendingDown.length ? `队员晕倒，时间已停止。待确认 ${pendingDown.map(e=>(s.party || []).find(p=>p.id===e.actor_id)?.name ?? e.actor_id).join("、")}` : "";
  $("confirm_down").disabled=caps.confirm_down !== true;
  const controlSelect=$('native_control_target');
  if(controlSelect){const previous=controlSelect.value;controlSelect.replaceChildren(...(s.control_targets || []).map(a=>{const o=document.createElement('option');o.value=String(a.id);o.textContent=a.name;return o;}));if([...controlSelect.options].some(o=>o.value===previous))controlSelect.value=previous;$('native_control').disabled=caps.native_control!==true;}
  const allyPrevious=$("ally_target").value;
  $("ally_target").replaceChildren(...(s.party || []).map(p=>{const o=document.createElement("option");o.value=String(p.id);o.textContent=`${p.name ?? p.id}${p.down ? "（晕倒）" : ""}`;return o;}));
  if ([...$("ally_target").options].some(o=>o.value===allyPrevious)) $("ally_target").value=allyPrevious;
  for(const id of ["takeover","return_control","rescue_start","rescue_step","rescue_cancel"]) $(id).disabled=caps[id] !== true;
  $("rescue_progress").textContent=s.rescue_progress ? `救援 ${s.rescue_progress.completed ?? 0}/20 回合` : "";
  const enemies = s.enemies || [], previous = $("target").value;
  $("target").replaceChildren(...enemies.map(e=>{const o=document.createElement("option");o.value=String(e.id);o.textContent=e.name ?? String(e.id);return o;}));
  if ([...$("target").options].some(o=>o.value===previous)) $("target").value=previous;
  $("enemies").replaceChildren(...enemies.map(e=>{const d=document.createElement("div");d.textContent=`${e.name ?? e.id} · ${JSON.stringify(e.position ?? (e.x != null && e.y != null ? [e.x,e.y] : "位置未知"))}${effects(e)}`;return d;}));
  $("resources").textContent = `弹药 ${s.ammo ?? "未知"}`;
  const config = s.ai_config;
  $("ai_apply").disabled = caps.ai_config !== true || !config;
  $("ai_defaults").disabled = caps.ai_config !== true || !config;
  if (config && typeof config === "object") {
    $("stop_rare").checked = config.stop_on_rare === true;
    $("stop_count").value = String(config.stop_enemy_count);
    $("ai_weights").replaceChildren(...(config.talents || []).map(({id,name,multiplier})=>{
      const wrap=document.createElement("label"), input=document.createElement("input");
      wrap.textContent = `${name || id} 自动权重 `;
      input.type="number"; input.min="0"; input.max="10"; input.step="0.1"; input.value=String(multiplier); input.dataset.talentWeight=id;
      wrap.appendChild(input); return wrap;
    }));
  } else { $("ai_weights").replaceChildren(); }
  const allTalents = Array.isArray(s.talents) ? s.talents : [];
  $("talent_status").replaceChildren(...allTalents.map(t=>{const d=document.createElement("div");d.textContent=`${t.name ?? t.id ?? "未知技能"} · ${skillEnabled(t,caps) ? "可用" : talentReason(t)} · 冷却 ${t.cooldown === false ? 0 : (t.cooldown ?? "未知")}${t.mode === "sustained" ? (t.active ? " · 持续中" : " · 未开启") : ""}${t.no_energy ? " · 不消耗行动能量" : ""} · 原生费用 ${t.resources == null ? "未知" : resourceCosts(t.resources)}`;return d;}));
  const talents = allTalents.filter(t=>t && typeof t.id === "string" && skillEnabled(t,caps));
  const previousTalent = $("talent").value;
  $("talent").replaceChildren(...talents.map(t=>{const o=document.createElement("option");o.value=t.id;o.textContent=t.name ?? t.id;return o;}));
  if ([...$("talent").options].some(o=>o.value===previousTalent)) $("talent").value=previousTalent;
  $("cast").disabled=caps.talent !== true || talents.length===0;
  updateTalentTarget();
  const events = s.events || [];
  $("events").replaceChildren(...(events.length ? events : ["尚未接通逐条原生战斗日志"]).map(e=>{const li=document.createElement("li");li.textContent=cleanLog(typeof e === "string" ? e : JSON.stringify(e));return li;}));
  if (typeof document.addEventListener === "function") renderHUD(s, cells);
}
async function observe(){
  try {
    const r=await fetch("/api/state",{cache:"no-store"});
    if(!r.ok) throw Error("原生服务不可用，战斗状态未知");
    display(await r.json());
  } catch(e) {
    freezeView("内核连接或结果未知；显示最后已确认的旧状态，操作已锁止");
    throw e;
  }
}
function command(payload, expectedEpoch=epoch, expectedGeneration=null){
  const task = queue.then(async()=>{
    if (expectedEpoch !== epoch || (expectedGeneration !== null && expectedGeneration !== generation)) return;
    if (!state) throw Error("尚未连接");
    const r=await fetch("/api/command",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({...payload,revision:state.revision})});
    const body=await r.json();
    if (!r.ok) { const error=Error(body.error || "操作失败"); error.status=r.status; if(r.status>=500) freezeView(error.message); else {try {await observe();} catch {}} throw error; }
    display(body);
  });
  queue=task.catch(e=>{if(!e.status || e.status>=500)freezeView('内核连接或结果未知；显示最后已确认的旧状态，操作已锁止');if(!state?.stale)$("status").textContent=e.message;});
  return task;
}
function manual(payload){targeting=null;gridAiming=false;generation++;command(payload).catch(()=>{});}
function moveToSelectedCell(p,rows){
  const hero=controlledActor(state);
  const dx=p.x-hero?.x, dy=p.y-hero?.y, tile=rows[p.y]?.[p.x];
  if(state?.capabilities?.move===true && Number.isInteger(dx) && Number.isInteger(dy) && Math.max(Math.abs(dx),Math.abs(dy))===1 && tile && tile!==" " && tile!=="#") {
    manual({type:"move",dx,dy}); return;
  }
  if(canStartNavigation(state)) navigate(p.x,p.y);
  else {stopNavigationForSelection();$("navigation_status").textContent="点击移动当前不可用";}
}
async function navigate(x,y){
  const mine=++generation;
  try {
    await command({type:"navigate_start",x,y},epoch,mine);
    const control=state?.control_epoch;
    while(mine===generation && state?.navigation?.status==="running" && state?.capabilities?.navigate_step===true && !terminal(state)) {
      await new Promise(resolve=>setTimeout(resolve,0));
      if(mine!==generation) break;
      await command({type:"navigate_step",control_epoch:control},epoch,mine);
    }
  } catch(e) {
    if ((!e.status || e.status>=500) && mine===generation) {
      $("navigation_status").textContent="移动请求结果未知，正在尝试暂停";
      try {await command({type:"pause"},epoch,mine); $("navigation_status").textContent="移动请求结果未知；已请求暂停，请检查状态";}
      catch {$("navigation_status").textContent="移动请求结果未知，无法确认暂停；请检查连接并接管";}
    }
  }
}
function stopNavigationForSelection(){
  if(state?.stale)return;
  if(state?.navigation?.status==="running") { generation++; epoch++; command({type:"pause"}).catch(()=>{}); }
}
document.querySelectorAll("[data-move]").forEach(b=>b.onclick=()=>{const [dx,dy]=b.dataset.move.split(",").map(Number);manual({type:"move",dx,dy});});
document.querySelectorAll("[data-command]").forEach(b=>b.onclick=()=>manual({type:b.dataset.command}));
for (const [id,mode] of [["melee","melee"],["ranged","ranged"]]) $(id).onclick=()=>{if($("target").value)manual({type:"attack",target:$("target").value,mode});};
$("ai_defaults").onclick=()=>{
  const talent_weights={};
  for(const t of state?.ai_config?.talents || []) talent_weights[t.id]=1;
  manual({type:"ai_config",stop_on_rare:false,stop_enemy_count:0,talent_weights});
};
$("ai_apply").onclick=()=>{
  const talent_weights={};
  document.querySelectorAll("[data-talent-weight]").forEach(input=>{talent_weights[input.dataset.talentWeight]=Number(input.value);});
  manual({type:"ai_config",stop_on_rare:$("stop_rare").checked,stop_enemy_count:Number($("stop_count").value),talent_weights});
};
$("confirm_down").onclick=()=>{const event=state?.down_events?.[0]; if(event) manual({type:"confirm_down",event_id:event.id,generation:state.generation});};
if($('native_control'))$('native_control').onclick=()=>{if($('native_control_target').value)manual({type:'native_control',target:$('native_control_target').value});};
$("takeover").onclick=()=>{if($("ally_target").value) manual({type:"takeover",target:$("ally_target").value});};
$("rescue_start").onclick=async()=>{
  if(!$("ally_target").value) return;
  const mine=++generation;
  try {
    await command({type:"rescue_start",target:$("ally_target").value},epoch,mine);
    const frozenControlEpoch=state?.control_epoch;
    while(mine===generation && state?.capabilities?.rescue_step===true && !terminal(state)) {
      await new Promise(resolve=>setTimeout(resolve,0));
      if(mine!==generation) break;
      await command({type:"rescue_step",control_epoch:frozenControlEpoch},epoch,mine);
    }
  } catch(e) {
    if(!e.status || e.status>=500) $("status").textContent="救援请求结果未知，请检查连接并暂停";
  }
};
$("rescue_step").onclick=()=>manual({type:"rescue_step",control_epoch:state?.control_epoch});
for(const id of ["return_control","rescue_cancel"]) $(id).onclick=()=>manual({type:id});
function updateTalentTarget(){
  const talent=(state?.talents || []).find(t=>t.id===$("talent").value);
  $("grid_target_controls").hidden=!(gridAiming && talent?.target === "grid");
  $("cast").textContent=talent?.mode === "sustained" && talent?.active ? "关闭持续技能" : "使用技能";
}
$("talent").onchange=()=>{targeting=null;gridAiming=false;updateTalentTarget();};
$("cancel_grid_target").onclick=()=>{targeting=null;gridAiming=false;updateTalentTarget();};
function beginTalent(){
  const id=$("talent").value, talent=(state?.talents || []).find(t=>t.id===id);
  if(!id || !talent || !skillEnabled(talent,state?.capabilities)) return;
  targeting=null;gridAiming=false;
  if(talent.target==='native'){manual({type:'talent',talent:id});return;}
  if(talent.target==='self'){manual({type:'talent',talent:id});return;}
  const candidates=Array.isArray(talent.target_ids)?talent.target_ids:[];
  if(talent.melee_target===true && candidates.length===1){manual({type:'talent',talent:id,target:String(candidates[0])});return;}
  targeting={id,generation:state.generation,actor:state.control_actor_id,target:talent.target};
  gridAiming=talent.target==='grid';updateTalentTarget();
  $("status").textContent=`${talent.name ?? id}：请点击${gridAiming?'目标格子':'目标生物'}，Esc取消`;
}
$("cast").onclick=beginTalent;
$("new").onclick=()=>{generation++; epoch++; command({type:"new_game",seed:Number($("seed").value)}).catch(()=>{});};
$("pause").onclick=()=>{generation++; epoch++; command({type:"pause"}).catch(()=>{});};
$("restart_after_end").onclick=()=>$("new").onclick();
$("export_diagnostics").onclick=async()=>{try {await window.tomeTransport.exportDiagnostics();}catch(e){$("runtime_message").textContent+=' 诊断导出失败：'+String(e.message);}};
function terminal(s){return ["input","await_input","terminal"].includes(s?.advance_status) || ["blocked_danger","danger","victory","defeat"].includes(s?.status) || ["blocked_danger","danger","victory","defeat"].includes(s?.pause_reason);}
async function startAutomation(mode){
  targeting=null;gridAiming=false;
  const limit=Number($("limit").value);
  if (!$("limit").value.trim() || !Number.isInteger(limit) || limit<1 || limit>500) {$("status").textContent="请输入 1 至 500 的整数步数"; return;}
  const mine=++generation;
  async function stopAfterUnknown() {
    if(state?.stale)return;
    if (mine!==generation) return;
    $("status").textContent="请求结果未知，正在尝试暂停";
    try { await command({type:"pause"},epoch,mine); }
    catch { $("status").textContent="请求结果未知，无法确认暂停；请检查连接并接管"; }
  }
  try {await queue; if (mine!==generation) return; await observe();} catch(e) {$("status").textContent=e.message; return;}
  if (mine!==generation || ["input","await_input","terminal"].includes(state?.advance_status) || state?.capabilities?.ai_start!==true) return;
  const continuous=state?.capabilities?.ai_continuous===true;
  const request={type:"ai_start",budget:limit}; if(state?.capabilities?.ai_modes?.includes(mode)) request.mode=mode; else if(mode!=="sweep") return; if(continuous) request.continuous=true;
  try {await command(request, epoch, mine);} catch(e) {if (!e.status || e.status>=500) await stopAfterUnknown(); return;}
  if (mine!==generation || state?.ai_status !== "running") return;
  const frozenEpoch=state?.control_epoch;
  while(mine===generation){
    try {
      if(state?.advance_status==="pending") await command({type:"continue_pending"},epoch,mine);
      else if(state?.capabilities?.ai_renew===true) await command({type:"ai_renew",budget:limit,control_epoch:frozenEpoch},epoch,mine);
      else if(state?.capabilities?.ai_step===true && state?.ai_remaining>0) await command({type:"ai_step",control_epoch:frozenEpoch},epoch,mine);
      else break;
    } catch(e) {if (!e.status || e.status>=500) await stopAfterUnknown(); break;}
    if (terminal(state) || state?.ai_status !== "running") break;
    await new Promise(resolve=>setTimeout(resolve,0));
  }
}
$("auto").onclick=()=>startAutomation("sweep");
$("explore").onclick=()=>startAutomation("explore");
$("rest").onclick=()=>startAutomation("rest");
// The canvas is a view of the observer response. The server remains authoritative.
let zoom = 25, camera = null, hoverGrid = null;
function renderHUD(s, cells) {
  const hero=controlledActor(s);
  const summary=$("hero_summary");
  summary.replaceChildren();
  const heading=document.createElement("strong");
  heading.textContent=hero ? `${hero.name ?? "未知"} · ${hero.race ?? "未知种族"} ${hero.class ?? "未知职业"} · ${hero.level ?? "?"}级` : "当前控制者未知";
  summary.appendChild(heading);
  if(hero?.visual?.kind==="representative"){const note=document.createElement("small");note.textContent="人物图：同族代表形象";summary.appendChild(note);}
  function bar(name,value,max,polarity,min) {
    const wrap=document.createElement("div"), title=document.createElement("span"), track=document.createElement("span"), fill=document.createElement("i");
    wrap.className="resource"; title.textContent=`${name} ${hp(value)} / ${max == null ? "未知" : hp(max)}${polarity === "lower" ? "（越低越好）" : ""}`;
    track.className="track"; if(typeof value==="number" && typeof min==="number" && typeof max==="number" && max>min) fill.style.width=`${Math.max(0,Math.min(100,100*(value-min)/(max-min)))}%`;
    track.appendChild(fill); wrap.append(title,track); summary.appendChild(wrap);
  }
  bar("生命",hero?.hp,hero?.max_hp,null,0);
  if(Array.isArray(hero?.resources) && hero.resources.length) hero.resources.forEach(r=>bar(r.name ?? r.id ?? "资源",r.value,r.max,resourceDirection(r),r.min));
  else {const missing=document.createElement("div");missing.textContent="资源：未知";summary.appendChild(missing);}
  $("party").replaceChildren(...(s.party || []).map(p=>{const d=document.createElement("div");d.className="party-row"+(p.id===s.control_actor_id?" selected":"");d.textContent=`${p.id===s.control_actor_id?"◆":"◇"} ${p.name ?? "未知"}  ${hp(p.hp)}/${hp(p.max_hp)}${p.down?" · 晕倒":""}`;return d;}));
  $("equipment_list").replaceChildren(...(s.party || []).map(p=>{
    const section=document.createElement("section"), heading=document.createElement("strong");
    heading.textContent=p.name ?? "未知队员";section.appendChild(heading);
    if(!Array.isArray(p.equipment)){const row=document.createElement("div");row.textContent="装备未知";section.appendChild(row);}
    else if(!p.equipment.length){const row=document.createElement("div");row.textContent="没有公开的已装备物品";section.appendChild(row);}
    else p.equipment.forEach(item=>{const row=document.createElement("div");
      row.textContent=`${item.slot ?? "未知槽位"}：${item.name ?? "未知装备"} · 状态 ${item.status ?? "未知"}`;
      if(item.source_name && item.source_name!==item.name){const detail=document.createElement("small");detail.textContent=`来源记录：${item.source_name}`;row.appendChild(detail);}
      section.appendChild(row);
    });
    return section;
  }));
  const ef=Array.isArray(hero?.effects)?hero.effects:[];
  for(const [id,status] of [["buffs","beneficial"],["debuffs","detrimental"],["unknown_effects","unknown"]]) {
    const list=ef.filter(e=>status==="unknown"?!["beneficial","detrimental"].includes(e.status):e.status===status);
    $(id).replaceChildren(...list.map(e=>{const d=document.createElement("div");d.className="effect";const url=assetURL(e.icon);if(url){nativeImage(e.icon);const img=document.createElement("span");img.style.backgroundImage=`url("${url}")`;img.className="effect-icon";img.setAttribute("aria-hidden","true");d.appendChild(img);}const text=document.createElement("span");text.textContent=e.id==="EFF_MERCENARY_DOWN" ? "晕倒（等待救援）" : `${e.name ?? e.id ?? "未知"} · ${e.dur ?? "未知"}`;d.appendChild(text);d.title=`来源：${e.source ?? "未知"}`;return d;}));
  }
  if(ef.some(e=>!["beneficial","detrimental"].includes(e.status))) $("unknown_effects").prepend("分类未知：");
  $("down_panel").hidden=!(s.down_events || []).length;
  $("manual_mode").classList.toggle("active",s.ai_status!=="running");
  $("auto").classList.toggle("active",s.ai_status==="running");
  const all=Array.isArray(s.talents)?s.talents:[], selected=$("talent").value;
  $("hotbar").replaceChildren(...all.map((t,i)=>{const b=document.createElement("button");b.className="skill"+(t.active?" sustained":"")+(t.id===selected?" selected":"");b.disabled=!skillEnabled(t,s.capabilities);
    const key=i<10?String((i+1)%10):i<20?`⇧${(i+1)%10}`:"";
    b.setAttribute("aria-label",cleanLog(t.name ?? t.id ?? "未知技能"));
    if(key) b.setAttribute("aria-keyshortcuts",i<10?key:`Shift+${(i+1)%10}`);
    const cost=t.effectivecost == null ? "未知" : resourceCosts(t.effectivecost);
    b.title=cleanLog(`${t.name ?? t.id}\n${t.description ?? ""}\n${skillEnabled(t,s.capabilities)?"可用":talentReason(t)} · 冷却 ${t.cooldown === false ? 0 : (t.cooldown ?? "未知")} · 实际消耗 ${cost}\n原生费用 ${t.resources == null ? "未知" : resourceCosts(t.resources)} · 范围 ${t.range ?? "未知"}`);
    const url=assetURL(t.icon);if(url){nativeImage(t.icon);const img=document.createElement("span");img.style.backgroundImage=`url("${url}")`;img.className="skill-icon";img.setAttribute("aria-hidden","true");b.appendChild(img);}
    const caption=document.createElement("span");caption.textContent=`${key} ${t.name ?? t.id}${t.active?" ●":""}${t.cooldown ? ` · ${t.cooldown}`:""}`;b.appendChild(caption);
    b.onclick=()=>{ $("talent").value=t.id;beginTalent();renderHUD(state,cells); };
    return b;}));
  drawMap(s,cells);
}
const imageCache=new Map();
const missingAssets=new Set();
let imageRedrawQueued=false;
function nativeImage(path) {
  const url=assetURL(path);if(!url)return null;
  if(!imageCache.has(url)){
    const img=new Image();imageCache.set(url,img);
    img.onload=()=>{if(imageRedrawQueued)return;imageRedrawQueued=true;requestAnimationFrame(()=>{imageRedrawQueued=false;if(state)drawMap(state,(state.map || []).map(r=>Array.from(r)));});};
    img.onerror=()=>{missingAssets.add(path);$("asset_notice").textContent=`部分素材不可用（${missingAssets.size}）`;$("asset_notice").title=Array.from(missingAssets).join("\n");};
    img.src=url;
  }
  const img=imageCache.get(url);
  return img.complete && img.naturalWidth ? img : null;
}
function drawNativeLayer(ctx,image,px,py,size,meta={}) {
 const tall=meta.auto_tall && image.naturalHeight>image.naturalWidth ? Math.min(4,image.naturalHeight/image.naturalWidth):1;
 const width=meta.display_w ?? 1,height=meta.display_h ?? tall;
 ctx.drawImage(image,px+(meta.display_x ?? 0)*size,py+(meta.display_y ?? (height>1?1-height:0))*size,width*size,height*size);
}
function drawMap(s,cells) {
  const canvas=$("battle_map"), ctx=canvas.getContext("2d"), rect=canvas.getBoundingClientRect();
  const dpr=window.devicePixelRatio || 1; canvas.width=Math.round(rect.width*dpr);canvas.height=Math.round(rect.height*dpr);ctx.setTransform(dpr,0,0,dpr,0,0);
  const w=rect.width,h=rect.height, hero=controlledActor(s), size=zoom;
  const cx=Number.isInteger(hero?.x)?hero.x:Math.floor((cells[0]?.length || 1)/2), cy=Number.isInteger(hero?.y)?hero.y:Math.floor(cells.length/2);
  camera={left:cx-Math.floor(w/size/2),top:cy-Math.floor(h/size/2),size};
  ctx.fillStyle="#101719";ctx.fillRect(0,0,w,h);
  const colors={"#":"#445457",".":"#283c39","@":"#72d7d0","a":"#b5d6a2","b":"#b5d6a2","e":"#ef8a73"," ":"#101719"};
  ctx.textAlign="center";ctx.textBaseline="middle";ctx.font=`600 ${Math.max(12,size*.58)}px monospace`;
  for(let y=0;y<cells.length;y++) for(let x=0;x<cells[y].length;x++){
    const px=(x-camera.left)*size,py=(y-camera.top)*size;if(px < -size || py < -size || px>w || py>h) continue;
    const c=cells[y][x], terrain=s.terrain_visuals?.[y]?.[x], tile=nativeImage(terrain?.image);
    ctx.fillStyle=c===" "?"#101719":c==="#"?"#344340":"#24332f";ctx.fillRect(px+1,py+1,size-2,size-2);
    if(tile)ctx.drawImage(tile,px,py,size,size);
    if(Array.isArray(terrain?.layers)) for(const layer of [...terrain.layers].sort((a,b)=>(a.z??0)-(b.z??0))){const overlay=nativeImage(layer.image);if(overlay)ctx.drawImage(overlay,px,py,size,size);}
    if(terrain && terrain.seen===false){ctx.fillStyle="#0009";ctx.fillRect(px,py,size,size);}
    if(c!==" " && c!=="." && c!=="#" && !["@", "a", "b", "e"].includes(c)){ctx.fillStyle=colors[c] || "#d5dfd1";ctx.fillText(c,px+size/2,py+size/2);}
  }
  for(const actor of [...(s.party || []),...(s.entities || []).filter(e=>e.id===s.control_actor_id || visibleEnemy(e,s,cells)),...(s.enemies || []).filter(e=>visibleEnemy(e,s,cells))]){
    if(!Number.isInteger(actor.x)||!Number.isInteger(actor.y))continue;
    const px=(actor.x-camera.left)*size,py=(actor.y-camera.top)*size;if(px < -size || py < -size || px>w || py>h)continue;
    const picture=nativeImage(actor.visual?.image);if(picture)drawNativeLayer(ctx,picture,px,py,size,actor.visual);
    else {ctx.fillStyle=(s.enemies || []).includes(actor)?"#ef8a73":"#72d7d0";ctx.fillText((s.enemies || []).includes(actor)?"e":"@",px+size/2,py+size/2);}
      for(const layer of actor.visual?.layers || []){const image=nativeImage(layer.image);if(image)drawNativeLayer(ctx,image,px,py,size,layer);}
  }
  const talent=(s.talents || []).find(t=>t.id===$("talent").value);
  if(hoverGrid && Number.isFinite(talent?.range) && Number.isInteger(hero?.x) && Number.isInteger(hero?.y)) {
    ctx.strokeStyle="#6c9d91";ctx.lineWidth=1;
    ctx.strokeRect((hero.x-talent.range-camera.left)*size,(hero.y-talent.range-camera.top)*size,(talent.range*2+1)*size,(talent.range*2+1)*size);
  }
  if(hoverGrid && gridAiming && talent?.target==="grid") {
    const px=(hoverGrid.x-camera.left)*size,py=(hoverGrid.y-camera.top)*size;
    ctx.strokeStyle="#f4ce78";ctx.lineWidth=2;ctx.strokeRect(px+1,py+1,size-2,size-2);
    if(typeof talent.radius==="number" && talent.radius>0){ctx.strokeStyle="#ddb665";ctx.strokeRect(px-talent.radius*size,py-talent.radius*size,(talent.radius*2+1)*size,(talent.radius*2+1)*size);}
  }
  const mini=$("minimap"), m=mini.getContext("2d"), mw=mini.width=192,mh=mini.height=192,rows=Array.isArray(s.explored_map)?s.explored_map:cells.map(r=>r.join(""));
  m.fillStyle="#111719";m.fillRect(0,0,mw,mh);
  const rw=rows[0]?.length || 1,rh=rows.length || 1;
  rows.forEach((row,y)=>Array.from(row).forEach((c,x)=>{if(c!==" "){m.fillStyle=c==="#"?"#718079":"#344844";m.fillRect(x*mw/rw,y*mh/rh,Math.ceil(mw/rw),Math.ceil(mh/rh));}}));
  for(const p of s.party || []) if(Number.isInteger(p.x)&&Number.isInteger(p.y)){m.fillStyle=p.id===s.control_actor_id?"#73e5d2":"#b2d598";m.fillRect(p.x*mw/rw,p.y*mh/rh,3,3);}
  const controlled=controlledActor(s);if(controlled && !(s.party || []).some(p=>p.id===controlled.id) && Number.isInteger(controlled.x) && Number.isInteger(controlled.y)){m.fillStyle="#73e5d2";m.fillRect(controlled.x*mw/rw,controlled.y*mh/rh,3,3);}
  for(const e of s.enemies || []) if(visibleEnemy(e,s,cells)){m.fillStyle="#ef8a73";m.fillRect(e.x*mw/rw,e.y*mh/rh,3,3);}
}
if(typeof document.addEventListener==="function") {
  $("manual_mode").onclick=()=>{if(state?.ai_status==="running" || state?.navigation?.status==="running") $("pause").onclick();};
  $("zoom_in").onclick=()=>{zoom=Math.min(42,zoom+3);renderHUD(state,(state.map || []).map(r=>Array.from(r)));};
  $("zoom_out").onclick=()=>{zoom=Math.max(16,zoom-3);renderHUD(state,(state.map || []).map(r=>Array.from(r)));};
  const canvas=$("battle_map");
  function point(e){const r=canvas.getBoundingClientRect();return {x:Math.floor((e.clientX-r.left)/camera.size)+camera.left,y:Math.floor((e.clientY-r.top)/camera.size)+camera.top};}
  canvas.addEventListener('contextmenu',async e=>{
    e.preventDefault();if(!camera || !state || state.stale)return;
    const p=point(e),actor=[...(state.party || []),...(state.entities || []),...(state.enemies || [])].find(a=>a.x===p.x&&a.y===p.y);
    if(!actor)return;
    const token=++inspectionToken,scene=state.generation;
    try{
      if(state.ai_status==='running' || state.navigation?.status==='running'){
        generation++;epoch++;await command({type:'pause'});
        if(state.stale || scene!==state.generation)return;
      }
      const response=await fetch('/api/inspect',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({target:actor.id})});
      const sheet=await response.json();
      if(token!==inspectionToken || scene!==state.generation || state.stale)return;
      if(!response.ok)throw Error(sheet.error || '无法查看');
      let dialog=$('creature_inspector');
      if(!dialog){dialog=document.createElement('dialog');dialog.id='creature_inspector';document.body.append(dialog);}
      const title=document.createElement('h2');title.textContent=`${sheet.name} · 等级 ${sheet.level}`;
      const content=document.createElement('div'),life=document.createElement('p');life.textContent=`生命 ${hp(sheet.hp)} / ${hp(sheet.max_hp)}`;content.append(life);
      const names={str:'力量',dex:'敏捷',con:'体质',mag:'魔法',wil:'意志',cun:'灵巧',accuracy:'命中',armour:'护甲',defence:'闪避',mental_save:'精神豁免',mind_power:'精神强度',physical_power:'物理强度',physical_save:'物理豁免',spell_power:'法术强度',spell_save:'法术豁免'};
      for(const [heading,values] of [['属性',sheet.stats],['战斗',sheet.combat],['抗性',sheet.resistances]]){
        const h=document.createElement('h3');h.textContent=heading;const list=document.createElement('dl');
        for(const [key,value] of Object.entries(values || {})){const dt=document.createElement('dt'),dd=document.createElement('dd');dt.textContent=names[key] || cleanLog(key);dd.textContent=hp(value);list.append(dt,dd);}
        if(!Object.keys(values || {}).length)list.textContent='未显示额外抗性';content.append(h,list);
      }
      for(const [heading,items] of [['装备',(sheet.equipment || []).map(x=>x.name)],['技能',(sheet.talents || []).map(t=>`${t.name} · 等级 ${t.rank} · ${{passive:'被动',sustained:'持续',activated:'主动'}[t.mode] || t.mode}`)]]){
        const h=document.createElement('h3');h.textContent=heading;const list=document.createElement('ul');for(const value of items){const li=document.createElement('li');li.textContent=cleanLog(value);list.append(li);}content.append(h,list);
      }
      const close=document.createElement('button');close.textContent='关闭';close.onclick=()=>dialog.close();
      dialog.replaceChildren(title,close,content);if(!dialog.open)dialog.showModal();
    }catch(error){$('status').textContent='生物查看失败：'+error.message;}
  });
  canvas.addEventListener("mousemove",e=>{if(!camera || !state)return;hoverGrid=point(e);drawMap(state,(state.map || []).map(r=>Array.from(r)));});
  canvas.addEventListener("mouseleave",()=>{hoverGrid=null;if(state) drawMap(state,(state.map || []).map(r=>Array.from(r)));});
  canvas.addEventListener("click",e=>{if(!camera || !state)return;const p=point(e);if(state.input_request?.kind==='target' && state.capabilities?.input_response){manual({type:'input_response',input_id:state.input_request.id,x:p.x,y:p.y});return;}const rows=state.explored_map || state.map || [];if(p.y<0||p.x<0||p.y>=rows.length||p.x>=rows[p.y].length||rows[p.y][p.x]===" "){stopNavigationForSelection();return;}
    const talent=(state.talents || []).find(t=>t.id===$("talent").value);
    if(targeting){
      const intent=targeting;
      if(intent.target==='grid'){targeting=null;gridAiming=false;updateTalentTarget();manual({type:'talent',talent:intent.id,x:p.x,y:p.y});return;}
      const foe=(state.enemies || []).find(a=>a.x===p.x&&a.y===p.y);
      if(foe && (talent?.target_ids || []).some(id=>String(id)===String(foe.id))){targeting=null;manual({type:'talent',talent:intent.id,target:String(foe.id)});}
      else $("status").textContent='此处没有合法目标；请重新选目标或按Esc取消';
      return;
    }
    const cells=(state.map || []).map(r=>Array.from(r));
    const enemy=(state.enemies || []).find(a=>a.x===p.x&&a.y===p.y&&visibleEnemy(a,state,cells));
    if(enemy){stopNavigationForSelection();$("target").value=String(enemy.id);return;}
    moveToSelectedCell(p,rows);
  });
  document.addEventListener("keydown",e=>{if(e.target.matches("input,select,textarea,[contenteditable], [contenteditable] *")||e.ctrlKey||e.altKey||e.metaKey)return;
    if($('creature_inspector')?.open)return;
    const dirs={ArrowUp:[0,-1],ArrowDown:[0,1],ArrowLeft:[-1,0],ArrowRight:[1,0],Numpad7:[-1,-1],Numpad8:[0,-1],Numpad9:[1,-1],Numpad4:[-1,0],Numpad6:[1,0],Numpad1:[-1,1],Numpad2:[0,1],Numpad3:[1,1]};
    const shortcut=automationShortcut(e);
    if(shortcut && !$(shortcut).disabled){e.preventDefault();$(shortcut).click();}
    else if(e.key==="Escape"){e.preventDefault();if(state?.input_request && state.capabilities?.input_response){manual({type:'input_response',input_id:state.input_request.id,cancel:true});return;}const wasTargeting=!!targeting;targeting=null;gridAiming=false;updateTalentTarget();if(!wasTargeting && state?.capabilities?.pause) $("pause").onclick();}
    else if(dirs[e.code] && state?.capabilities?.move){e.preventDefault();manual({type:"move",dx:dirs[e.code][0],dy:dirs[e.code][1]});}
    else if((e.code==="Numpad5"||e.code==="Space"||e.key===".") && state?.capabilities?.wait && !(e.code==="Space" && e.repeat)){e.preventDefault();manual({type:"wait"});}
    else if(/^Digit[0-9]$/.test(e.code)){const n=(Number(e.code.slice(-1))+9)%10+(e.shiftKey?10:0),button=$("hotbar").children[n];if(button&&!button.disabled){e.preventDefault();button.click();}}
  });
  window.addEventListener("resize",()=>{if(state) renderHUD(state,(state.map || []).map(r=>Array.from(r)));});
  window.addEventListener('tome-runtime-failed',()=>freezeView('内核退出或连接失效；显示最后已确认的旧状态，操作已锁止'));
  window.addEventListener('tome-stop-automation',()=>{generation++;epoch++;targeting=null;gridAiming=false;});
  window.addEventListener('tome-session-state',e=>display(e.detail));
  if(typeof ResizeObserver==="function") new ResizeObserver(()=>{if(state) drawMap(state,(state.map || []).map(r=>Array.from(r)));}).observe(canvas);
}
observe().catch(e=>{$("status").textContent=e.message;});
