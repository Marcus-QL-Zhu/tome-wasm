"use strict";
// Run only against a dedicated candidate session, not an existing user's game.
// Usage: node tests/tome_ui_navigation_real_e2e.js http://127.0.0.1:PORT X Y
const fs=require("fs"),vm=require("vm"),assert=require("node:assert/strict");
const [base,xs,ys]=process.argv.slice(2),x=Number(xs),y=Number(ys);
if(!base || !Number.isSafeInteger(x) || !Number.isSafeInteger(y)) throw Error("Supply dedicated session URL and explored destination X Y");
const nodes={},node=id=>nodes[id] ||= {id,dataset:{},value:"",options:[],replaceChildren(...v){this.options=v;},textContent:"",disabled:false};
const document={getElementById:node,querySelectorAll:()=>[],createElement:()=>({dataset:{},appendChild(){}})},calls=[];
async function wrapped(url,opts={}){const r=await fetch(base+url,{...opts,headers:{...opts.headers,Origin:base}});if(opts.method){const req=JSON.parse(opts.body),body=await r.clone().json();calls.push({req,status:r.status,body});}return r;}
const context={document,fetch:wrapped,setTimeout,console};vm.createContext(context);vm.runInContext(fs.readFileSync("tome_mvp/web/app.js","utf8"),context);
(async()=>{for(let i=0;i<200 && !vm.runInContext("state !== null",context);i++)await new Promise(r=>setTimeout(r,50));
 assert(vm.runInContext("state?.capabilities?.navigate_start === true",context),"navigation unavailable");
 assert.equal(vm.runInContext("state?.capabilities?.navigate_step",context),false,"initial step must be unavailable");
 assert.equal(vm.runInContext("canStartNavigation(state)",context),true,"initial click gate must permit start");
 await vm.runInContext(`navigate(${x},${y})`,context);assert.equal(calls[0]?.req.type,"navigate_start");
 assert(calls.every(c=>c.status===200),"navigation request rejected");assert(calls.some(c=>c.req.type==="navigate_step"),"no native step");
 const last=calls.at(-1).body;assert.notEqual(last.navigation?.status,"running","navigation still running");
 console.log(JSON.stringify({calls:calls.map(({req,status,body})=>({type:req.type,status,revision:body.revision,turn:body.turn,navigation:body.navigation})),final:last.navigation},null,2));
})().catch(e=>{console.error(e);process.exitCode=1;});
