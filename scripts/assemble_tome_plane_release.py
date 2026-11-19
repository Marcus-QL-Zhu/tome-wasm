"""Assemble the plane-capable release from an audited DLC kernel and native build."""
from argparse import ArgumentParser
from hashlib import sha256
import json
from pathlib import Path
import shutil

parser = ArgumentParser(description=__doc__)
parser.add_argument('--base', required=True, type=Path)
parser.add_argument('--native', required=True, type=Path)
parser.add_argument('--output', required=True, type=Path)
args = parser.parse_args()
base, native, out = (path.resolve() for path in (args.base, args.native, args.output))
if out.exists() or any(out.is_relative_to(path) for path in (base, native)):
    parser.error('--output must be a new directory outside each input')
source_root = Path(__file__).resolve().parents[1]
shutil.copytree(base, out)
public = out / 'public'
for name in ('tome.wasm', 'tome.js', 'tome.data'):
    shutil.copyfile(native / name, public / name)
ids = json.loads((out / 'identity.json').read_bytes())
old_id = ids['build_id']
inputs = ids['inputs']
sha = lambda raw: sha256(raw).hexdigest()
tracked = ('worker', 'content_policy', 'native_zone', 'native_save_partition_scene',
           'units', 'native_control', 'native_function_env', 'native_actions', 'headless_visuals',
           'native_catalog_anchor', 'native_save_partition', 'rescue')
modules = {name+'.lua': (source_root / 'tome_mvp/headless' / (name+'.lua')).read_text(encoding='utf-8') for name in tracked}
for name, text in modules.items():
    raw = text.encode()
    inputs['lua']['bundle/headless/'+name] = {'bytes':len(raw),'sha256':sha(raw)}
runtime = public / 'kernel_runtime.mjs'
original = runtime.read_text(encoding='utf-8')
anchor = ' if(hooks.prepare)await hooks.prepare(mod);'
assert original.count(anchor) == 1
patch = (source_root / 'tome_mvp/wasm/native_zone_overlay.mjs').read_text(encoding='utf-8')
start = patch.index(" for(const path of ['psionic/slumber'")
end = patch.index(' if(mission)',start)
plane_patch = patch[start:end]
install = """const planeModules = %s;
function installPlaneModules(mod) {
 for(const [name,source] of Object.entries(planeModules))mod.FS.writeFile('/bundle/headless/'+name, source);
 const patch=(path,needle,replacement)=>{
  const s=mod.FS.readFile(path,{encoding:'utf8'});
  if(s.includes(replacement))return;
  if(s.split(needle).length!==2)throw Error('unexpected plane talent source: '+path);
  mod.FS.writeFile(path,s.replace(needle,replacement));
 };
 %s
}
""" % (json.dumps(modules),plane_patch)
runtime.write_text(install + original.replace(anchor, ' installPlaneModules(mod);\n'+anchor), encoding='utf-8')
for name in ('client.js','engine_bridge.mjs','browser_checkpoint.mjs'):
    shutil.copyfile(source_root / 'tome_mvp/wasm' / name, public/name)
inputs['native_plane_probe'] = {'base_build_id':old_id,'binary_sha256':sha((public/'tome.wasm').read_bytes()),
    'binding_sha256':sha((native/'pure_noise.c').read_bytes()), 'overlay_sha256':sha(install.encode())}
for path in inputs['host_scripts']:
    raw=(out/path).read_bytes()
    inputs['host_scripts'][path]={'bytes':len(raw),'sha256':sha(raw)}
ids['build_id']=sha(json.dumps(inputs,sort_keys=True).encode())[:16]
worker=public/'browser_worker.mjs'
worker.write_text(worker.read_text(encoding='utf-8').replace(old_id,ids['build_id']),encoding='utf-8')
(out/'identity.json').write_text(json.dumps(ids,indent=2),encoding='utf-8')
build=json.loads((out/'build.json').read_bytes())
build['command']=json.loads((native/'rebuild-command.json').read_bytes())
for name in ('tome.js','tome.wasm','tome.data'):
    raw=(public/name).read_bytes()
    build['outputs'][name]={'bytes':len(raw),'sha256':sha(raw)}
(out/'build.json').write_text(json.dumps(build,indent=2),encoding='utf-8')
print(ids['build_id'])
