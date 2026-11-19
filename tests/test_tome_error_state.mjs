import {test} from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import {readFileSync} from 'node:fs';
import {EngineBridge} from '../tome_mvp/wasm/engine_bridge.mjs';
import {DiagnosticRecorder} from '../tome_mvp/wasm/diagnostics.mjs';

test('unknown result retains the last observation but locks all actions without another RPC',async()=>{
 let calls=0;
 const original={generation:1,turn:11,status:'active',map:['#@.'],party:[{id:1,hp:42}],enemies:[],events:['last damage'],capabilities:{wait:true}};
 const b=new EngineBridge(async(method)=>{calls++;if(method==='capabilities')return {protocol:'tome-headless-v1',web_commands:{wait:true},methods:{observe:true}};if(method==='create')return {accepted:true,generation:1,boundary:'decision'};if(method==='observe')return structuredClone(original);throw Error('simulated native failure');});
 await b.init();assert.equal((await b.command({type:'wait',revision:0})).status,500);
 const s=b.state();assert.equal(s.stale,true);assert.equal(s.status,'unknown');assert.deepEqual(s.map,original.map);assert.deepEqual(s.party,original.party);assert.deepEqual(s.events,original.events);assert.deepEqual(s.capabilities,{});
 const n=calls;assert.equal((await b.command({type:'wait',revision:1})).status,500);assert.equal(calls,n);
});
test('diagnostic report retains the first failure and a bounded, immutable transcript',()=>{
 const r=new DiagnosticRecorder('test-build');const original={map:['@'],party:[{hp:10}]};r.observe(original);original.party[0].hp=0;
 r.request('create',{seed:42},1);
 for(let i=0;i<150;i++)r.request('act',{n:i},1);
 for(let i=0;i<300;i++)r.log('line',i);
 r.fail('native_failure','first stack');r.fail('pause_failed','later noise');const a=r.export();
 assert.equal(a.first_error.code,'native_failure');assert.equal(a.first_error.detail,'first stack');assert.equal(a.first_error.last_confirmed.party[0].hp,10);assert.equal(a.requests.length,128);assert.equal(a.lines.length,256);
 assert.equal(a.seed,42);
 r.nativeReport('NATIVE_LOCAL_ERROR_REPORT_JSON {"details":"stack\\nonTakeoff"}');assert.equal(r.export().native_report_count,1);assert.equal(r.export().recoverable_native_reports[0].request.method,'act');assert.match(r.export().recoverable_native_reports[0].message,/onTakeoff/);assert.equal(r.export().first_error.code,'native_failure');
 a.first_error.code='tampered';assert.equal(r.export().first_error.code,'native_failure');
});
test('a malformed victory observation cannot replace the confirmed battlefield',async()=>{
 let bad=false;
 const original={generation:1,turn:1,status:'active',map:['@'],party:[{id:1}],enemies:[],events:['last'],capabilities:{wait:true}};
 const b=new EngineBridge(async(method)=>{if(method==='capabilities')return {protocol:'tome-headless-v1',web_commands:{wait:true},methods:{observe:true}};if(method==='create'||method==='act')return {accepted:true,generation:1,boundary:'decision'};if(method==='observe')return bad?{generation:1,status:'victory'}:structuredClone(original);});
 await b.init();bad=true;assert.equal((await b.command({type:'wait',revision:0})).status,500);assert.equal(b.state().stale,true);assert.deepEqual(b.state().map,['@']);assert.equal(b.state().status,'unknown');
});
test('web freezes its last map on transport loss rather than replacing it with empty arrays',()=>{
 const nodes={};const node=id=>nodes[id] ||= {value:'',options:[],dataset:{},replaceChildren(...a){this.options=a;},textContent:''};
 const document={getElementById:node,querySelectorAll:()=>[],createElement:()=>({dataset:{},appendChild(){}})};
 const ctx={document,fetch:()=>new Promise(()=>{}),console,setTimeout};vm.createContext(ctx);vm.runInContext(readFileSync('tome_mvp/web/app.js','utf8'),ctx);
 vm.runInContext(`state={map:['#@.'],party:[{id:1,hp:10}],events:['last attack'],capabilities:{wait:true}};freezeView('simulated loss')`,ctx);
 assert.equal(vm.runInContext('state.stale',ctx),true);assert.equal(vm.runInContext('state.map[0]',ctx),'#@.');assert.equal(vm.runInContext('state.party[0].hp',ctx),10);assert.equal(nodes.runtime_notice.hidden,false);assert.match(nodes.runtime_message.textContent,/旧画面/);assert.equal(nodes.manual_mode.disabled,true);
});
