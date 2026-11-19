import test from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import fs from 'node:fs';
function setup(talent){
 const nodes=new Map();const document={getElementById:id=>{if(!nodes.has(id))nodes.set(id,{value:'',style:{},dataset:{},appendChild(){}});return nodes.get(id);},querySelectorAll:()=>[]};
 const c={document,console,setTimeout,fetch:()=>new Promise(()=>{})};vm.createContext(c);vm.runInContext(fs.readFileSync('tome_mvp/web/app.js','utf8'),c);
 c.input=talent;vm.runInContext(`calls=[];manual=p=>calls.push(p);state={generation:4,control_actor_id:1,capabilities:{talent:true},talents:[input]};document.getElementById('talent').value=input.id`,c);
 return {c,nodes,run:s=>vm.runInContext(s,c)};
}
test('ranged skill starts target selection and ignores a preselected enemy',()=>{
 const s=setup({id:'T_MANATHRUST',available:true,target:'hostile',range:10,target_ids:[2]});
 s.nodes.set('target',{value:'2'});s.run('beginTalent()');
 assert.equal(s.run('calls.length'),0);assert.equal(s.run('targeting.id'),'T_MANATHRUST');
});
test('only one native eligible melee target permits immediate use',()=>{
 for(const ids of [[],[2],[2,3]]){
  const s=setup({id:'T_SHIELD_PUMMEL',available:true,target:'hostile',range:1,melee_target:true,target_ids:ids});s.run('beginTalent()');
  assert.equal(s.run('calls.length'),ids.length===1?1:0);
 }
});
test('grid selection waits for a click while self skills execute immediately',()=>{
 const grid=setup({id:'T_FIREFLASH',available:true,target:'grid'});grid.run('beginTalent()');assert.equal(grid.run('calls.length'),0);assert.equal(grid.run('gridAiming'),true);
 const self=setup({id:'T_BLOCK',available:true,target:'self'});self.run('beginTalent()');assert.equal(self.run('calls.length'),1);assert.equal(self.run('targeting'),null);
});
