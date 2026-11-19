"use strict";
const {test} = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs"), vm = require("node:vm");
const nodes = {};
function node(id) {return nodes[id] ||= {id,dataset:{},value:"",options:[],replaceChildren(...x){this.options=x;},textContent:""};}
const document = {getElementById:node,querySelectorAll:()=>[],createElement:()=>({dataset:{},appendChild(){}})};
const ctx = {document,fetch:()=>new Promise(()=>{}),console,setTimeout};
vm.createContext(ctx);
vm.runInContext(fs.readFileSync("tome_mvp/web/app.js","utf8"),ctx);
function evaluate(source){return vm.runInContext(source,ctx);}
test("only explicitly available supported target skills can be used",()=>{
  assert.equal(evaluate('skillEnabled({available:true,target:"hostile"},{talent:true})'),true);
  assert.equal(evaluate('skillEnabled({available:false,target_schema:"needs_input",reason:"unsupported_talent"},{talent:true})'),false);
  assert.equal(evaluate('skillEnabled({available:true,target:"unknown",target_schema:"needs_input"},{talent:true})'),false);
  assert.equal(evaluate('skillEnabled({available:true,target:"self"},{talent:false})'),false);
  assert.equal(evaluate('talentReason({reason:"unsupported_talent"})'),"原生桥尚不支持");
});
test("minimap rejects enemies outside current vision",()=>{
  assert.equal(evaluate('visibleEnemy({x:1,y:0},{visible_map:["01"]},[[".","e"]])'),true);
  assert.equal(evaluate('visibleEnemy({x:1,y:0},{visible_map:["00"]},[[".","e"]])'),false);
  assert.equal(evaluate('visibleEnemy({x:1,y:0},{},[[".","e"]])'),true);
  assert.equal(evaluate('visibleEnemy({x:1,y:0},{},[[".","."]])'),false);
});
test("resource direction follows native switch direction, not cost inversion",()=>{
  assert.equal(evaluate('resourceDirection({switch_direction:true})'),"lower");
  assert.equal(evaluate('resourceDirection({invert_values:true,switch_direction:false})'),null);
  assert.equal(evaluate('resourceDirection({})'),null);
});

test('controlled native body supplies HUD and targeting data outside the core roster',()=>{
  assert.equal(evaluate('controlledActor({control_actor_id:9,party:[{id:1}],controlled_actor:{id:9,name:"golem"}}).name'),'golem');
  assert.equal(evaluate('controlledActor({control_actor_id:1,party:[{id:1,name:"leader"}]}).name'),'leader');
});
test('campaign withdrawal is distinct from original defeat and never offers reset',()=>{
  assert.match(evaluate('terminalPresentation({status:"defeat",campaign_bound:true,campaign_withdrawn:true}).message'),/团长已撤出/);
  assert.equal(evaluate('terminalPresentation({status:"defeat",campaign_bound:true,campaign_withdrawn:true}).hideRestart'),true);
  assert.equal(evaluate('terminalPresentation({status:"defeat",campaign_bound:true,campaign_withdrawn:false}).hideNew'),true);
  assert.match(evaluate('terminalPresentation({status:"defeat",campaign_bound:true,campaign_withdrawn:false}).message'),/全队已倒地/);
  assert.equal(evaluate('terminalPresentation({status:"defeat",campaign_bound:false}).hideRestart'),false);
  assert.equal(evaluate('terminalPresentation({status:"victory",campaign_bound:true}).hideRestart'),true);
});
