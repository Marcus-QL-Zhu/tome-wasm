import {readFile} from 'node:fs/promises';import {resolve} from 'node:path';import {pathToFileURL} from 'node:url';
const d=resolve('artifacts/native-save-core-20261115/experimental14/public'),{default:create}=await import(pathToFileURL(resolve(d,'tome.js'))),data=await readFile(resolve(d,'tome.data'));let lines=[];
const m=await create({wasmBinary:await readFile(resolve(d,'tome.wasm')),getPreloadedPackage:()=>data.buffer.slice(data.byteOffset,data.byteOffset+data.byteLength),print:s=>lines.push(s),printErr:s=>lines.push(s)});
m.FS.writeFile('/bundle/headless/native_partition_store.lua',await readFile('tome_mvp/headless/native_partition_store.lua','utf8'));
m.FS.writeFile('/bundle/headless/worker.lua',await readFile('tests/tome_native_partition_registry.lua','utf8')+'\nprotocol_read()');
const init=m.cwrap('tome_init','number',[]),result=m.cwrap('tome_result','string',[]);const rc=init();if(rc)throw Error(result());if(!lines.some(x=>x.includes('NATIVE_PARTITION_REGISTRY_PASS')))throw Error('no registry pass');console.log('real Wasm native partition registry passed');
