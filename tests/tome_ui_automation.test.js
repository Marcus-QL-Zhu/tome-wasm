"use strict";
const {test}=require("node:test"), assert=require("node:assert/strict"), fs=require("node:fs"), vm=require("node:vm");
function setup(continuous){
 const nodes={}; const node=id=>nodes[id] ||= {id,dataset:{},value:id==='limit'?'1':'',options:[],replaceChildren(...a){this.options=a;},textContent:""};
 const document={getElementById:node,querySelectorAll:()=>[],createElement:()=>({dataset:{},appendChild(){}})};
 const calls=[];let step=0,rev=0;const caps={ai_start:true,ai_step:true,...(continuous?{ai_continuous:true,ai_modes:['sweep','explore','rest']}:{})};
 let state={revision:0,control_epoch:2,capabilities:caps,ai_status:'stopped',ai_remaining:0};
 const fetch=async(url,opts={})=>{if(!opts.method)return {ok:true,json:async()=>state};const p=JSON.parse(opts.body);calls.push(p);rev++;if(p.type==='ai_start') state={...state,revision:rev,ai_status:'running',ai_remaining:1};
 else if(p.type==='ai_step'){step++;state={...state,revision:rev,ai_remaining:0,ai_status:continuous?'running':'stopped',capabilities:{...caps,ai_renew:continuous}};}
 else if(p.type==='ai_renew')state={...state,revision:rev,ai_remaining:1,capabilities:{...caps,ai_renew:false}};
 if(step===2)state={...state,ai_status:'stopped',capabilities:caps};return {ok:true,json:async()=>state};};
 const c={document,fetch,setTimeout,console};vm.createContext(c);vm.runInContext(fs.readFileSync('tome_mvp/web/app.js','utf8'),c);vm.runInContext('display = s => {state=s}',c);return {c,calls};
}
test('continuous UI renews without restarting and exits on native stop',async()=>{const {c,calls}=setup(true);await vm.runInContext('startAutomation("explore")',c);assert.deepEqual(calls.map(x=>x.type),['ai_start','ai_step','ai_renew','ai_step']);assert.equal(calls[0].mode,'explore');assert.equal(calls[0].continuous,true);});
test('legacy service receives legacy start and bounded steps',async()=>{const {c,calls}=setup(false);await vm.runInContext('startAutomation("sweep")',c);assert.deepEqual(calls.map(x=>x.type),['ai_start','ai_step']);assert.deepEqual(Object.keys(calls[0]).sort(),['budget','revision','type']);});
test('native alerts show actual health and do not infer DOT warnings',()=>{
 const {c}=setup(true);
 assert.equal(vm.runInContext('automationAlertText({party:[{id:1,name:"Akud"}],ai_alert:null})',c),'');
 assert.match(vm.runInContext('automationAlertText({party:[{id:1,name:"Akud"}],ai_alert:[{kind:"threshold",actor_id:1,percent:25,hp:20,max_hp:100}]})',c),/Akud.*25%.*20\.0\/100\.0.*20\.0%.*倒地另行确认/);
 assert.match(vm.runInContext('automationAlertText({party:[{id:1,name:"Akud"}],ai_alert:[{kind:"damage",actor_id:1,loss:30,hp:60,max_hp:100}]})',c),/单步掉血 30\.0/);
});
test('automation shortcuts ignore repeat without globally rejecting movement repeats',()=>{
 const {c}=setup(true);assert.equal(vm.runInContext('automationShortcut({code:"KeyZ",repeat:false})',c),'explore');assert.equal(vm.runInContext('automationShortcut({code:"KeyR",repeat:true})',c),null);
 const src=fs.readFileSync('tome_mvp/web/app.js','utf8');assert.doesNotMatch(src,/e\.metaKey\|\|e\.repeat/);
});
