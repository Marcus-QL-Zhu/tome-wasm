"""Freeze Lua/host adapters over an immutable native kernel, without recompiling it."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
from zipfile import ZipFile

ROOT = Path(__file__).resolve().parents[1]


def installed_vault_rules(install):
    sources = {}
    with ZipFile(install / 'game/engines/te4-1.7.6.teae') as engine:
        for name in ('RoomsLoader', 'Static'):
            path = 'engine/generator/map/' + name + '.lua'
            source = engine.read(path).decode('utf8')
            # The frozen Wasm kernel has no XML parser. These definitions are Lua maps.
            eager_import = 'local lom = require "lxp.lom"'
            assert source.count(eager_import) == source.count('lom.parse(') == 1
            sources['/bundle/engine/' + path] = source.replace(eager_import, '').replace(
                'lom.parse(', '(require "lxp.lom").parse(')
    maps = ('auto/lesser/circle', 'auto/lesser/skeleton-mage-cabal', 'auto/lesser/crystal-cabal',
            'auto/lesser/rat-nest', 'amon-sul-crypt', 'snake-pit')
    files = ('data/rooms/simple.lua', 'data/rooms/lesser_vault.lua',
             *('data/maps/vaults/' + name + '.lua' for name in maps))
    directories = {}
    with ZipFile(install / 'game/modules/tome.team') as tome:
        for path in files:
            sources['/bundle/tome/' + path] = tome.read(path).decode('utf8')
            parent, name = path.rsplit('/', 1)
            directories.setdefault('/' + parent, []).append(name)
    registration = 'TOME_VAULT_RULES_READY=true\n'
    for path, names in sorted(directories.items()):
        key = json.dumps(path)
        members = ','.join(json.dumps(name) for name in sorted(names))
        registration += (
            f'do local names=list[{key}] or {{}}; list[{key}]=names; '
            f'for _,name in ipairs({{{members}}}) do local exists=false; '
            'for _,current in ipairs(names) do if current==name then exists=true; break end end; '
            'if not exists then names[#names+1]=name end end; table.sort(names) end\n')
    return sources, registration


def build(base, output, *, company=False, install=None):
    base = Path(base).resolve(strict=True)
    output = Path(output).resolve()
    if output.exists():
        raise FileExistsError(output)
    identity = json.loads((base / 'identity.json').read_text(encoding='utf8'))
    sha = lambda raw: hashlib.sha256(raw).hexdigest()
    if sha(json.dumps(identity['inputs'], sort_keys=True).encode())[:16] != identity['build_id']:
        raise ValueError('base identity mismatch')
    if 'public/kernel_runtime.mjs' not in identity['inputs']['host_scripts']:
        raise ValueError('kernel runtime is not a tracked host dependency')
    module_names = ('worker.lua', 'scene_placement.lua', 'local_area.lua', 'native_save_partition_scene.lua',
                    'dm_transition.lua', 'campaign_transition.lua', 'localization.lua', 'json_validate.lua')
    if company:
        module_names = ('worker.lua', 'scene_placement.lua', 'local_area.lua', 'native_save_partition_scene.lua', 'native_partition_store.lua',
                        'campaign_transition.lua', 'campaign_items.lua', 'campaign_loadout.lua', 'campaign_wipeout.lua', 'rescue.lua',
                        'character_editor.lua', 'company_roster.lua', 'dm_native.lua',
                        'dm_progression.lua', 'formal_roster.lua', 'content_policy.lua', 'native_control.lua', 'native_dialogs.lua', 'native_inputs.lua',
                        'formal_map.lua', 'formal_scene.lua', 'formal_factory.lua', 'native_zone.lua',
                        'native_function_env.lua', 'native_catalog_anchor.lua', 'headless_visuals.lua', 'native_partition_transfer.lua',
                        'native_save_partition.lua', 'units.lua')
    modules = {name: (ROOT / 'tome_mvp/headless' / name).read_text(encoding='utf8') for name in module_names}
    if install and not company:
        raise ValueError('installed vault rules require a company overlay')
    vault_files, vault_directories = installed_vault_rules(Path(install)) if install else ({}, '')
    public = output / 'public'
    shutil.copytree(base / 'public', public)
    shutil.copytree(base / 'host', output / 'host')
    shutil.copyfile(base / 'build.json', output / 'build.json')
    compat = (ROOT / 'tome_mvp/wasm/native_zone_overlay.mjs').read_text(encoding='utf8')
    if compat.count('export function installNativeZoneFixes(') != 1:
        raise ValueError('native compatibility export changed')
    overlay = compat.replace('export function installNativeZoneFixes(', 'function installNativeZoneFixes(') + "\nconst unifiedBattleModules=" + json.dumps(modules) + ";\nfunction installUnifiedBattle(mod){for(const[n,s]of Object.entries(unifiedBattleModules))mod.FS.writeFile('/bundle/headless/'+n,s);installNativeZoneFixes(mod,{mission:true});}\n"
    runtime = (public / 'kernel_runtime.mjs').read_text(encoding='utf8')
    anchor = ' if(hooks.prepare)await hooks.prepare(mod);'
    if runtime.count(anchor) != 1:
        raise ValueError('native prepare boundary changed')
    already_unified = ' installUnifiedBattle(mod);' in runtime
    if company:
        if not already_unified or 'installCompanyModules' in runtime:
            raise ValueError('company requires a unified battle base')
        overlay = ('const companyModules=' + json.dumps(modules) +
                   ";\nfunction installCompanyModules(mod){for(const[n,s]of Object.entries(companyModules))mod.FS.writeFile('/bundle/headless/'+n,s);}\n")
        install_hook = ' installCompanyModules(mod);\n'
        if vault_files:
            overlay += ('const vaultFiles=' + json.dumps(vault_files) + ';\n'
                        'const vaultDirectories=' + json.dumps(vault_directories) + ';\n'
                        "function installVaultRules(mod){const fs=mod.FS;for(const[p,s]of Object.entries(vaultFiles)){"
                        "fs.mkdirTree(p.slice(0,p.lastIndexOf('/')));fs.writeFile(p,s);}"
                        "const boot='/bundle/generated/probe.lua',anchor='    local function norm';"
                        "const src=fs.readFile(boot,{encoding:'utf8'});"
                        "if(src.split(anchor).length!==2)throw Error('unknown vault bootstrap boundary');"
                        "fs.writeFile(boot,src.replace(anchor,()=>vaultDirectories+anchor));}\n")
            install_hook += ' installVaultRules(mod);\n'
    else:
        if already_unified or 'installNativeZoneFixes' in runtime:
            raise ValueError('base runtime already contains a unified overlay')
        install_hook = ' installUnifiedBattle(mod);\n'
    (public / 'kernel_runtime.mjs').write_text(overlay + runtime.replace(anchor, install_hook + anchor), encoding='utf8')
    transport = (ROOT / 'tome_mvp/wasm/partition_transport.mjs').read_text(encoding='utf8')
    for folder in (public, output / 'host'):
        (folder / 'partition_transport.mjs').write_text(transport, encoding='utf8')
    host = (ROOT / 'scripts/tome_partition_host.mjs').read_text(encoding='utf8')
    for name in ('partition_session_host.mjs', 'partition_transport.mjs'):
        host = host.replace('../tome_mvp/wasm/' + name, './' + name)
    host = host.replace('../tome_mvp/wasm/battle_session.mjs', '../public/battle_session.mjs')
    (output / 'host/tome_partition_host.mjs').write_text(host, encoding='utf8')
    if company:
        shutil.copyfile(ROOT / 'scripts/tome_validate_operations.mjs', output / 'host/tome_validate_operations.mjs')
        session_host = (ROOT / 'tome_mvp/wasm/partition_session_host.mjs').read_text(encoding='utf8')
        (output / 'host/partition_session_host.mjs').write_text(
            session_host.replace("'./partition_session.mjs'", "'../public/partition_session.mjs'"), encoding='utf8')
        for name in ('engine_bridge.mjs', 'battle_session.mjs', 'partition_session.mjs'):
            shutil.copyfile(ROOT / 'tome_mvp/wasm' / name, public / name)
    material = identity['inputs']
    material['company' if company else 'unified_battle'] = {
        'base_build_id': identity['build_id'], 'modules': {n: sha(s.encode()) for n, s in modules.items()},
        'overlay_sha256': sha(overlay.encode()), 'compat_sha256': sha(compat.encode())}
    if vault_files:
        material['company']['vault_rules'] = {name: sha(source.encode()) for name, source in vault_files.items()}
    for name, source in modules.items():
        material['lua']['bundle/headless/' + name] = {'sha256': sha(source.encode()), 'bytes': len(source.encode())}
    worker = (public / 'browser_worker.mjs').read_text(encoding='utf8')
    if worker.count(identity['build_id']) != 1:
        raise ValueError('worker identity boundary changed')
    if company:
        web = ROOT / 'tome_mvp/wasm'
        browser_sources = {}
        for name in ('client.js', 'browser_checkpoint.mjs'):
            path = public / name
            shutil.copyfile(web / name, path)
            browser_sources[name] = sha(path.read_bytes())
        worker = (web / 'browser_worker.mjs').read_text(encoding='utf8')
        browser_sources['browser_worker.mjs'] = sha(worker.encode())
        material['company']['browser_sources'] = browser_sources
        worker = worker.replace('__TOME_BUILD_ID__', identity['build_id']).replace('__TOME_ENCOUNTER_SEED__', '12')
    for relative in material['host_scripts']:
        path = output / relative
        material['host_scripts'][relative] = {'sha256': sha(path.read_bytes()), 'bytes': path.stat().st_size}
    build_id = sha(json.dumps(material, sort_keys=True).encode())[:16]
    (public / 'browser_worker.mjs').write_text(worker.replace(identity['build_id'], build_id), encoding='utf8')
    identity['build_id'] = build_id
    (output / 'identity.json').write_text(json.dumps(identity, indent=2), encoding='utf8')
    return build_id


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--base', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--company', action='store_true')
    parser.add_argument('--install', type=Path, help='Installed ToME 1.7.6 for native vault Lua definitions')
    args = parser.parse_args()
    print(build(args.base, args.output, company=args.company, install=args.install))
