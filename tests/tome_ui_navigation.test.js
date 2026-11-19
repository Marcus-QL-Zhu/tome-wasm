"use strict";
const {test}=require("node:test"), assert=require("node:assert/strict"), fs=require("node:fs"), vm=require("node:vm");
function setup(failStep=false){
 const nodes={}; const node=id=>nodes[id] ||= {id,dataset:{},value:"",options:[],replaceChildren(...a){this.options=a;},textContent:""};
 const document={getElementById:node,querySelectorAll:()=>[],createElement:()=>({dataset:{},appendChild(){}})};
 let rev=1; const calls=[]; let current={revision:rev,control_epoch:8,capabilities:{navigate_start:true,navigate_step:false},navigation:{status:"idle"}};
 const fetch=async (url,opts={})=>{
  if(!opts.method) return {ok:true,json:async()=>current};
  const p=JSON.parse(opts.body); calls.push(p);
  current={...current,revision:++rev,capabilities:{navigate_start:true,navigate_step:p.type==="navigate_start"},navigation:{status:p.type==="navigate_start"?"running":p.type==="navigate_step"?"stopped":"stopped",x:3,y:4,stop_reason:p.type==="navigate_step"?"arrived":"user_stop"}};
  if(failStep && p.type==="navigate_step") throw Error("lost response");
  return {ok:true,json:async()=>current};
 };
 const c={document,fetch,setTimeout,console};vm.createContext(c);vm.runInContext(fs.readFileSync("tome_mvp/web/app.js","utf8"),c);
 vm.runInContext('display = s => {state=s}; state={revision:1,control_epoch:8,capabilities:{navigate_start:true,navigate_step:false},navigation:{status:"idle"}}',c);
 return {c,calls,nodes};
}
test("navigation uses bounded steps and current revision",async()=>{
 const {c,calls}=setup(); await vm.runInContext('navigate(3,4)',c);
 assert.deepEqual(calls.map(c=>c.type),["navigate_start","navigate_step"]);
 assert.equal(calls[0].revision,1);assert.equal(calls[1].revision,2);assert.equal(calls[1].control_epoch,8);
});
test("unknown result never replays a navigation step",async()=>{
 const {c,calls,nodes}=setup(true);await vm.runInContext('navigate(3,4)',c);
  assert.deepEqual(calls.map(c=>c.type),["navigate_start","navigate_step"]);
  assert.equal(vm.runInContext('state.stale',c),true);
  assert.deepEqual(Object.keys(vm.runInContext('state.capabilities',c)),[]);
  assert.match(vm.runInContext('state.message',c),/结果未知/);
  assert.match(vm.runInContext('state.message',c),/操作已锁止/);
  assert.equal(vm.runInContext('state.status',c),'unknown');
  assert.equal(vm.runInContext('state.revision',c),2);
});

test("initial navigation needs start capability, not step capability",async()=>{
 const {c,calls}=setup();assert.equal(vm.runInContext('canStartNavigation(state)',c),true);
 assert.equal(vm.runInContext('state.capabilities.navigate_step',c),false);
 await vm.runInContext('navigate(3,4)',c);assert.deepEqual(calls.map(c=>c.type),["navigate_start","navigate_step"]);
});
test("session wall clock is human readable",()=>{const {c}=setup();assert.equal(vm.runInContext('sessionDuration(1232000)',c),"20分32秒");});

test("adjacent known tile uses exactly one existing move command",async()=>{
 const {c,calls}=setup();
 vm.runInContext('state.party=[{id:1,x:4,y:4}];state.control_actor_id=1;state.capabilities.move=true',c);
 vm.runInContext('moveToSelectedCell({x:3,y:3},["      ","      ","      ","   .  ","      "])',c);
 await vm.runInContext('queue',c);
 assert.deepEqual(calls.map(c=>c.type),["move"]);assert.equal(calls[0].dx,-1);assert.equal(calls[0].dy,-1);
});
