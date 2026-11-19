import hashlib, json, re, shutil
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
base=ROOT/'artifacts/dm-canonical-repair-20261113/source-kernel'
out=ROOT/'artifacts/dm-canonical-repair-20261113/kernel-document-v1'
if out.exists(): raise SystemExit('candidate already exists')
identity=json.loads((base/'identity.json').read_text(encoding='utf-8'))
old_id=identity['build_id']
js=(base/'public/tome.js').read_text(encoding='utf-8')
m=re.search(r'filename:"/bundle/headless/campaign_items.lua",start:(\d+),end:(\d+)',js)
if not m: raise ValueError('frozen source index missing')
data=(base/'public/tome.data').read_bytes()
old=data[int(m[1]):int(m[2])]
digest=lambda b:hashlib.sha256(b).hexdigest()
old_hash=digest(old)
if old_hash!=identity['inputs']['lua']['bundle/headless/campaign_items.lua']['sha256']: raise ValueError('frozen source hash mismatch')
anchor="  local prototype\r\n  for _,p in ipairs(game.zone.object_list or {})"
if old.decode('utf-8').count(anchor)!=1: raise ValueError('ambiguous insertion anchor')
patch="  if spec.prototype=='ordinary document' then require('project_items').install(game.zone.object_list) end\r\n"
project=(ROOT/'tome_mvp/headless/project_items.lua').read_text(encoding='utf-8')
overlay='''const expected=EXPECTED, anchor=ANCHOR, patch=PATCH, project=PROJECT;
export async function installDocumentOverlay(mod){
 const path='/bundle/headless/campaign_items.lua';
 const bytes=mod.FS.readFile(path);
 const hash=Array.from(new Uint8Array(await globalThis.crypto.subtle.digest('SHA-256',bytes))).map(x=>x.toString(16).padStart(2,'0')).join('');
 if(hash!==expected)throw Error('document overlay base hash mismatch');
 const source=new TextDecoder('utf-8',{fatal:true}).decode(bytes);
 if(source.split(anchor).length!==2)throw Error('document overlay anchor mismatch');
 mod.FS.writeFile(path,source.replace(anchor,patch+anchor));
 mod.FS.writeFile('/bundle/headless/project_items.lua',project);
}
'''.replace('EXPECTED',json.dumps(old_hash)).replace('ANCHOR',json.dumps(anchor)).replace('PATCH',json.dumps(patch)).replace('PROJECT',json.dumps(project,ensure_ascii=True))
material={'format':'tome-document-overlay-v1','base_build_id':old_id,'campaign_items_sha256':old_hash,'project_items_sha256':digest(project.encode()),'overlay_sha256':digest(overlay.encode()),'insertion_sha256':digest(patch.encode()),'base_files':{n:digest((base/'public'/n).read_bytes()) for n in ('tome.js','tome.data','tome.wasm','kernel_runtime.mjs')}}
new_id=digest(json.dumps(material,ensure_ascii=False,sort_keys=True,separators=(',',':')).encode())
shutil.copytree(base,out)
public=out/'public'
runtime=(public/'kernel_runtime.mjs').read_text(encoding='utf-8')
needle=' if(hooks.prepare)await hooks.prepare(mod);'
if runtime.count(needle)!=1:raise ValueError('kernel prepare anchor mismatch')
runtime="import {installDocumentOverlay} from './document_overlay.mjs';\n"+runtime.replace(needle,' await installDocumentOverlay(mod);\n'+needle)
(public/'kernel_runtime.mjs').write_text(runtime,encoding='utf-8',newline='\n')
(public/'document_overlay.mjs').write_text(overlay,encoding='utf-8',newline='\n')
worker=(public/'browser_worker.mjs').read_text(encoding='utf-8')
if worker.count(old_id)!=1: raise ValueError('browser build anchor mismatch')
(public/'browser_worker.mjs').write_text(worker.replace(old_id,new_id),encoding='utf-8',newline='\n')
identity['build_id']=new_id; identity['document_overlay']=material
(out/'identity.json').write_text(json.dumps(identity,ensure_ascii=False,indent=2),encoding='utf-8')
(out/'document-manifest.json').write_text(json.dumps({'build_id':new_id,**material},ensure_ascii=False,indent=2),encoding='utf-8')
print(new_id)
