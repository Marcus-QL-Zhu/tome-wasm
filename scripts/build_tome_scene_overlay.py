"""Freeze current map/placement adapters over an existing native Wasm build."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--base', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    base, out = args.base.resolve(strict=True), args.output.resolve()
    if out.exists():
        raise FileExistsError(out)
    identity = json.loads((base/'identity.json').read_text(encoding='utf8'))
    modules = {name: (ROOT/'tome_mvp/headless'/name).read_text(encoding='utf8') for name in
               ('formal_map.lua', 'formal_factory.lua', 'formal_scene.lua', 'campaign_transition.lua',
                'native_zone.lua','native_name_grammars.lua','rescue.lua','scene_placement.lua','dm_transition.lua',
                'scene.lua','player_aioo.lua','content_policy.lua','dm_progression.lua')}
    digest = lambda b: hashlib.sha256(b).hexdigest()
    gear_patch = "equipment=equipment,gear_score=(function()local n=0;for id,inv in pairs(a.inven or {})do if a.inven_def[id] and a.inven_def[id].is_worn then for _,o in ipairs(inv)do n=n+(o.material_level or 0)end end end;return n end)()"
    native_compat=(ROOT/'tome_mvp/wasm/native_zone_overlay.mjs').read_text(encoding='utf8')
    material = {'base_build_id': identity['build_id'], 'gear_projection': gear_patch,'native_zone_compat':digest(native_compat.encode()),
                'lua': {k: digest(v.encode()) for k, v in modules.items()}}
    build = digest(json.dumps(material, sort_keys=True).encode())
    # Copy only the runnable package and identity, not any saves or old experiments.
    shutil.copytree(base/'public', out/'public')
    public = out/'public'
    (public/'native_zone_overlay.mjs').write_text(native_compat,encoding='utf8')
    overlay = "import {installNativeZoneFixes} from './native_zone_overlay.mjs';\nexport function installSceneOverlay(mod){\ninstallNativeZoneFixes(mod,{mission:true});\n"
    for name, source in modules.items():
        overlay += 'mod.FS.writeFile('+json.dumps('/bundle/headless/'+name)+','+json.dumps(source)+');\n'
    # Preserve the base's inventory projection and its own dependencies.
    overlay += "const path='/bundle/headless/dm_native.lua',source=mod.FS.readFile(path,{encoding:'utf8'});\n"
    overlay += "if(source.split('equipment=equipment').length!==2)throw Error('unknown native equipment projection');\n"
    overlay += "mod.FS.writeFile(path,source.replace('equipment=equipment',"+json.dumps(gear_patch)+"));\n"
    overlay += '}\n'
    (public/'scene_overlay.mjs').write_text(overlay, encoding='utf8', newline='\n')
    runtime = (public/'kernel_runtime.mjs').read_text(encoding='utf8')
    needle = ' if(hooks.prepare)await hooks.prepare(mod);'
    if runtime.count(needle) != 1:
        raise ValueError('unknown kernel prepare boundary')
    runtime = "import {installSceneOverlay} from './scene_overlay.mjs';\n" + runtime.replace(needle, ' installSceneOverlay(mod);\n'+needle)
    (public/'kernel_runtime.mjs').write_text(runtime, encoding='utf8', newline='\n')
    worker = (public/'browser_worker.mjs').read_text(encoding='utf8')
    if worker.count(identity['build_id']) != 1:
        raise ValueError('unknown worker build boundary')
    (public/'browser_worker.mjs').write_text(worker.replace(identity['build_id'],build), encoding='utf8', newline='\n')
    identity.update(build_id=build, scene_overlay=material)
    (out/'identity.json').write_text(json.dumps(identity,indent=2), encoding='utf8')
    print(json.dumps({'build_id':build,'root':str(out)}))


if __name__ == '__main__':
    main()
