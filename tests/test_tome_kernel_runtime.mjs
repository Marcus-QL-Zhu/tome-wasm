import test from 'node:test';
import assert from 'node:assert/strict';
import {createKernel} from '../tome_mvp/wasm/kernel_runtime.mjs';

test('initialization failure preserves bounded native diagnostic', async () => {
 let calls=0;
 const create=async()=>({cwrap:(name)=>({tome_init:()=>1,tome_request:()=>{throw Error('unexpected request')},tome_result:()=>{calls++;return 'native failure: '+ 'x'.repeat(2000)}}[name])});
 await assert.rejects(createKernel(create), e => {
  assert.ok(e.message.startsWith('Wasm initialization failed: native failure: '));
  assert.equal(e.message.length,'Wasm initialization failed: '.length+1000);
  return true;
 });
 assert.equal(calls,1);
});

test('successful initialization does not read result early', async () => {
 let calls=0;
 const create=async()=>({cwrap:(name)=>({tome_init:()=>0,tome_request:()=>0,tome_result:()=>{calls++;return ''},tome_free:()=>{}}[name])});
 const kernel=await createKernel(create);assert.equal(calls,0);kernel.dispose();
});
