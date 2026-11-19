"""Freeze the native XP adapter; share immutable large assets via hard links."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil

ROOT=Path(__file__).resolve().parents[1]


def build(base,out):
    base=Path(base).resolve(strict=True);out=Path(out).resolve()
    if out.exists():raise ValueError('output already exists')
    identity=json.loads((base/'identity.json').read_text(encoding='utf8'))
    modules={name:(ROOT/'tome_mvp/headless'/name).read_text(encoding='utf8')for name in
             ('dm_transition.lua','dm_progression.lua')}
    sha=lambda b:hashlib.sha256(b).hexdigest()
    before={p.name:sha(p.read_bytes())for p in (base/'public').iterdir()if p.is_file()}
    projection_patch="const path='/bundle/headless/dm_native.lua';let source=mod.FS.readFile(path,{encoding:'utf8'});if(source.split('equipment=equipment').length!==2)throw Error('native XP projection boundary unavailable');source=source.replace('equipment=equipment',\"equipment=equipment,progression=require('dm_progression').snapshot(a)\");mod.FS.writeFile(path,source);const scene='/bundle/headless/formal_scene.lua';let setup=mod.FS.readFile(scene,{encoding:'utf8'});if(setup.split('function M.create(logs)').length!==2)throw Error('unknown scene initialization');mod.FS.writeFile(scene,setup.replace('function M.create(logs)',\"function M.create(logs)\\n require('dm_progression').install()\"));"
    overlay='const modules='+json.dumps(modules)+';\nexport function installExperience(mod){for(const[n,s]of Object.entries(modules))mod.FS.writeFile("/bundle/headless/"+n,s);'+projection_patch+'}\n'
    material={'base_build_id':identity['build_id'],'base_files':before,'overlay_sha256':sha(overlay.encode()),
              'modules':{k:sha(v.encode())for k,v in modules.items()}}
    build_id=sha(json.dumps(material,sort_keys=True).encode())
    public=out/'public';public.mkdir(parents=True)
    for p in (base/'public').iterdir():
        if p.is_file():
            if p.name in ('tome.wasm','tome.data','tome.js'):
                try:os.link(p,public/p.name)
                except OSError:shutil.copyfile(p,public/p.name)
            else:shutil.copyfile(p,public/p.name)
    (public/'experience_overlay.mjs').write_text(overlay,encoding='utf8')
    runtime=(public/'kernel_runtime.mjs').read_text(encoding='utf8');anchor=' if(hooks.prepare)await hooks.prepare(mod);'
    if runtime.count(anchor)!=1:raise ValueError('unknown native prepare boundary')
    (public/'kernel_runtime.mjs').write_text("import {installExperience} from './experience_overlay.mjs';\n"+runtime.replace(anchor,' installExperience(mod);\n'+anchor),encoding='utf8')
    worker=(public/'browser_worker.mjs').read_text(encoding='utf8')
    if worker.count(identity['build_id'])!=1:raise ValueError('unknown worker identity')
    (public/'browser_worker.mjs').write_text(worker.replace(identity['build_id'],build_id),encoding='utf8')
    identity.update(build_id=build_id,experience_overlay=material)
    (out/'identity.json').write_text(json.dumps(identity,indent=2),encoding='utf8')
    return build_id


if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--base',type=Path,required=True);p.add_argument('--output',type=Path,required=True);a=p.parse_args()
    print(build(a.base,a.output))
