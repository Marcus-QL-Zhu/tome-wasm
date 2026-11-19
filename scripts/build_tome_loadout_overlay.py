"""Freeze the camp loadout Lua boundary over an existing immutable ToME kernel."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil

ROOT=Path(__file__).resolve().parents[1]
def sha(raw):return hashlib.sha256(raw).hexdigest()

def build(base,out):
    base=base.resolve(strict=True);out=out.resolve()
    if out.exists():raise ValueError('output must not exist')
    identity=json.loads((base/'identity.json').read_text(encoding='utf-8'))
    modules={name:(ROOT/'tome_mvp/headless'/name).read_text(encoding='utf-8') for name in ('campaign_loadout.lua','campaign_items.lua','dm_native.lua')}
    before={p.name:sha(p.read_bytes()) for p in (base/'public').iterdir() if p.is_file()}
    material={'format':'tome-camp-loadout-v1','base_build_id':identity['build_id'],'base_files':before,
              'modules':{name:sha(text.encode()) for name,text in modules.items()}}
    build_id=sha(json.dumps(material,sort_keys=True,separators=(',',':')).encode())
    public=out/'public';public.mkdir(parents=True)
    for p in (base/'public').iterdir():
        if p.is_file():
            shutil.copyfile(p,public/p.name)
            if sha((public/p.name).read_bytes())!=before[p.name]:raise ValueError('base changed while freezing')
    overlay='const modules='+json.dumps(modules,ensure_ascii=True)+';\nexport function installLoadout(mod){for(const [name,text] of Object.entries(modules))mod.FS.writeFile("/bundle/headless/"+name,text);}\n'
    (public/'loadout_overlay.mjs').write_text(overlay,encoding='utf-8',newline='\n')
    runtime=(public/'kernel_runtime.mjs').read_text(encoding='utf-8');anchor=' if(hooks.prepare)await hooks.prepare(mod);'
    if runtime.count(anchor)!=1:raise ValueError('kernel preparation boundary unavailable')
    runtime="import {installLoadout} from './loadout_overlay.mjs';\n"+runtime.replace(anchor,' installLoadout(mod);\n'+anchor)
    (public/'kernel_runtime.mjs').write_text(runtime,encoding='utf-8',newline='\n')
    worker=(public/'browser_worker.mjs').read_text(encoding='utf-8')
    if worker.count(identity['build_id'])!=1:raise ValueError('build identity boundary unavailable')
    (public/'browser_worker.mjs').write_text(worker.replace(identity['build_id'],build_id),encoding='utf-8',newline='\n')
    identity.update(build_id=build_id,loadout_overlay=material)
    (out/'identity.json').write_text(json.dumps(identity,ensure_ascii=False,indent=2),encoding='utf-8')
    (out/'loadout-manifest.json').write_text(json.dumps(material,indent=2),encoding='utf-8')
    return build_id

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--base',type=Path,required=True);p.add_argument('--output',type=Path,required=True);a=p.parse_args()
    print(build(a.base,a.output))
