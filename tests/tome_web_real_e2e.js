"use strict";
// Executes the shipped app.js event handlers against the real local HTTP service.
const fs = require("fs"), vm = require("vm"), assert = require("assert");
const [base, scenario] = process.argv.slice(2), nodes = {};
function node(id) {
  return nodes[id] ||= {id, dataset:{}, value:id === "limit" ? "100" : id === "seed" ? "11" : "", options:[],
    replaceChildren(...children){this.options=children;}, textContent:"", disabled:false};
}
const document = {getElementById:node, querySelectorAll:()=>[], createElement:()=>({dataset:{},appendChild(){}})};
const calls = []; let lost = false;
async function wrapped(url, opts={}) {
  const response = await fetch(base + url, {...opts, headers:{...(opts.headers || {}), Origin:base}});
  if (opts.method === "POST") {
    const request=JSON.parse(opts.body), result=await response.clone().json();
    calls.push({request, status:response.status, response:result});
    if (scenario === "rescue_pause" && request.type === "rescue_step" && !lost) {lost=true; node("pause").onclick();}
    if (scenario === "response_loss" && request.type === "ai_step" && !lost) {
      lost=true; throw Error("injected response loss after server execution");
    }
  }
  return response;
}
const context={document,fetch:wrapped,setTimeout,console}; vm.createContext(context);
vm.runInContext(fs.readFileSync("tome_mvp/web/app.js","utf8"),context);
const sleep=ms=>new Promise(resolve=>setTimeout(resolve,ms));
async function state(){return (await wrapped("/api/state")).json();}
async function ready(){
  for(let i=0;i<100 && !vm.runInContext("state !== null",context);i++) await sleep(50);
  assert(vm.runInContext("state !== null",context),"initial state unavailable");
}
async function stable(turn, count){await sleep(1000);assert.equal((await state()).turn,turn);assert.equal(calls.length,count);}
async function stopAndRestart(){
  for(const value of ["1.5","", "0", "501"]){node("limit").value=value;await node("auto").onclick();assert.equal(calls.length,0);assert(node("status").textContent.includes("整数"));}
  node("stop_count").value="1"; node("ai_apply").onclick(); await vm.runInContext("queue",context);
  const initial=await state(); assert.equal(initial.ai_config.stop_enemy_count,1); assert.equal(initial.turn,0);
  node("limit").value="100";await node("auto").onclick();
  const stopped=calls.at(-1).response; assert.equal(stopped.ai_status,"stopped");
  assert(stopped.ai_stop_reason,"native stop reason missing");
  assert.match(stopped.ai_stop_reason,/^#RED#AI stopped: [1-9][0-9]* enemies spotted [(]Limit: 1[)]!$/);
  assert.equal(stopped.turn,initial.turn);
  assert.equal(calls.filter(c=>c.request.type==="ai_step").length,1);
  assert.notEqual(stopped.ai_stop_reason,"budget_exhausted");
  assert(calls.filter(c=>c.request.type==="ai_step").length < 100);
  const oldEpoch=calls.find(c=>c.request.type==="ai_start").response.control_epoch;
  const count=calls.length;await stable(stopped.turn,count);
  const latest=await state();
  const stale=await wrapped("/api/command",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({type:"ai_step",revision:latest.revision,control_epoch:oldEpoch})});
  assert.equal(stale.status,409);
  node("stop_count").value="0"; node("ai_apply").onclick(); await vm.runInContext("queue",context);
  assert.equal((await state()).ai_config.stop_enemy_count,0);
  node("limit").value="1";await node("auto").onclick();
  assert.equal(calls.at(-2).request.type,"ai_start");assert.equal(calls.at(-1).request.type,"ai_step");
  assert.equal(calls.at(-1).response.ai_stop_reason,"budget_exhausted");
  assert.equal(calls.at(-1).response.ai_status,"stopped");
  assert(node("status").textContent.includes("步数预算结束"));
}
async function responseLoss(){
  await node("auto").onclick();assert(lost);
  assert.deepEqual(calls.map(x=>x.request.type),["ai_start","ai_step","pause"]);
  const current=await state();assert.equal(current.ai_status,"stopped");await stable(current.turn,calls.length);
}
async function recoveryTransition(){
  const before=await state();assert.equal(before.fixture,"recovery");
  node("limit").value="25";await node("auto").onclick();const last=calls.at(-1).response;
  assert.equal(last.ai_status,"stopped");assert(last.ai_stop_reason);
  assert(calls.some(c=>c.response.ai_phase==="rest"));assert(calls.some(c=>c.response.ai_phase==="explore"));
  assert(last.party[0].hp>before.party[0].hp);await stable(last.turn,calls.length);
}
async function downEvents(){
  node("limit").value="100"; await node("auto").onclick();
  let first=await state(); assert.equal(first.status,"awaiting_down_confirmation");
  assert.equal(first.ai_status,"stopped"); assert.equal(first.down_events.length,1);
  const firstEvent=first.down_events[0], oldEpoch=calls.find(c=>c.request.type==="ai_start").response.control_epoch;
  assert.equal(first.capabilities.save,false); assert.equal(first.save_unavailable_reason,"callbacks_pending");
  const blocked=await wrapped("/api/command",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({type:"wait",revision:first.revision})});
  assert.equal(blocked.status,403); assert.equal((await state()).turn,first.turn);
  node("confirm_down").onclick(); await vm.runInContext("queue",context);
  let ack=await state(); assert.equal(ack.turn,first.turn); assert.equal(ack.ai_status,"stopped");
  if(ack.capabilities.continue_pending) {vm.runInContext('manual({type:"continue_pending"})',context); await vm.runInContext("queue",context);}
  assert.equal((await state()).ai_status,"stopped");
  node("limit").value="100"; await node("auto").onclick();
  let second=await state(); assert.equal(second.status,"awaiting_down_confirmation"); assert(second.down_events[0].id>firstEvent.id);
  assert.notEqual(second.down_events[0].actor_id,firstEvent.actor_id);
  const stale=await wrapped("/api/command",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({type:"confirm_down",event_id:firstEvent.id,generation:second.generation,revision:second.revision})});
  assert.notEqual(stale.status,200); second=await state(); assert.equal(second.status,"awaiting_down_confirmation");
  const oldAI=await wrapped("/api/command",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({type:"ai_step",revision:second.revision,control_epoch:oldEpoch})});
  assert.equal(oldAI.status,409); assert.equal((await state()).turn,second.turn);
}
async function rescuePause(){
  const before=await state(); const leader=before.party[0], rescuer=before.party[1];
  node("confirm_down").onclick(); await vm.runInContext("queue",context);
  node("ally_target").value=String(rescuer.id); node("takeover").onclick(); await vm.runInContext("queue",context);
  node("ally_target").value=String(leader.id); await node("rescue_start").onclick(); await vm.runInContext("queue",context);
  const current=await state(); const steps=calls.filter(c=>c.request.type==="rescue_step");
  assert.equal(steps.length,1); assert(current.rescue_progress); assert(current.party[0].down);
  const oldEpoch=steps[0].request.control_epoch; assert.notEqual(current.control_epoch,oldEpoch);
  const stale=await wrapped("/api/command",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({type:"rescue_step",revision:current.revision,control_epoch:oldEpoch})});
  assert.equal(stale.status,409); node("rescue_cancel").onclick(); await vm.runInContext("queue",context);
  const cancelled=await state(); assert.equal(cancelled.rescue_progress,null); assert(cancelled.party[0].down);
  const turn=cancelled.turn, count=calls.length; await stable(turn,count);
}
async function rescueFlow(){
  const before=await state(); assert.equal(before.status,"awaiting_down_confirmation"); assert(before.mission_complete);
  const leader=before.party[0], rescuer=before.party[1]; assert(leader.down); assert(leader.effects.some(e=>e.name==="晕倒")); assert.equal(before.control_actor_id,leader.id);
  node("ally_target").value=String(rescuer.id); node("takeover").onclick(); await vm.runInContext("queue",context);
  let current=await state(); assert.equal(current.control_actor_id,rescuer.id); assert.equal(current.status,"awaiting_down_confirmation");
  assert.equal(current.turn,before.turn); assert.equal(current.down_events[0].id,before.down_events[0].id);
  node("confirm_down").onclick(); await vm.runInContext("queue",context); current=await state(); assert.equal(current.turn,before.turn);
  if(current.capabilities.continue_pending) {vm.runInContext('manual({type:"continue_pending"})',context); await vm.runInContext("queue",context); current=await state();}
  assert.equal(current.status,"pending_rescue");
  node("ally_target").value=String(leader.id); await node("rescue_start").onclick();
  current=await state(); assert.equal(current.status,"victory"); assert.equal(current.party[0].down,false);
  assert(Math.abs(current.party[0].hp-current.party[0].max_hp*.2)<1e-8);
  const steps=calls.filter(x=>x.request.type==="rescue_step"); assert.equal(steps.length,20);
  assert(steps.some(x=>x.response.rescue_progress?.completed===20));
  assert(steps.every(x=>x.status===200 && x.request.control_epoch===steps[0].request.control_epoch));
  node("return_control").onclick(); await vm.runInContext("queue",context); current=await state();
  assert.equal(current.control_actor_id,leader.id); assert.equal(current.status,"victory");
}
(async()=>{
  await ready();
  if(scenario==="stop_restart") await stopAndRestart();
  else if(scenario==="response_loss") await responseLoss();
  else if(scenario==="recovery_transition") await recoveryTransition();
  else if(scenario==="rescue") await rescueFlow();
  else if(scenario==="rescue_pause") await rescuePause();
  else if(scenario==="down_events") await downEvents();
  else throw Error("unknown scenario");
  process.stdout.write(JSON.stringify({scenario,calls},null,2));
})().catch(error=>{console.error(error);console.error("TRACE " + JSON.stringify(calls));process.exitCode=1;});
