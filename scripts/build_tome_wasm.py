"""Build the real ToME C/Lua kernel as a local-only browser module.

The SDK and upstream sources are external build inputs. No Steam files or
running worker are changed. All generated files remain under artifacts/.
"""
from pathlib import Path
import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from tome_build_paths import SOURCE, RUNTIME, ADDON, SDK
SRC = SOURCE / "src"


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def checked(path, expected):
    if digest(path) != expected:
        raise SystemExit(f"Source hash mismatch: {path}")
    return path.read_text(encoding="utf-8")


def project_tactical_ai(runtime, out, manifest):
    """Snapshot and order native candidates before random tactical scoring."""
    source = runtime / "tome/mod/ai/improved_tactical.lua"
    raw = source.read_bytes()
    upstream_sha = hashlib.sha256(raw).hexdigest()
    expected = "db5766f6d3b4da93ce8d275dae2dcbd5655d0626fb4329242c9abe754c9c9829"
    old = b"for tid, lvl in pairs(t_list) do"
    new = b"for tid, lvl in table.orderedPairs(table.clone(t_list, false)) do"
    if upstream_sha != expected or raw.count(old) != 1:
        raise SystemExit("Unknown improved_tactical.lua source or iterator layout")
    projected = raw.replace(old, new, 1)
    target = out / "bundle/headless/mod/ai/improved_tactical.lua"
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(projected)
    projection_sha = hashlib.sha256(projected).hexdigest()
    manifest[target.relative_to(out).as_posix()] = {"sha256": projection_sha, "bytes": len(projected)}
    provenance = {"source": "runtime/tome/mod/ai/improved_tactical.lua", "source_sha256": upstream_sha,
                  "projection": target.relative_to(out).as_posix(), "projection_sha256": projection_sha,
                  "line": 496, "before": old.decode("ascii"), "after": new.decode("ascii")}
    (out / "ai-projection.json").write_text(json.dumps(provenance, indent=2) + "\n", encoding="utf-8")


def project_rule_boundaries(runtime, out, manifest):
    """Add settlement after complete native actions; preserve native cursors."""
    sources = [
        ("engine/engine/GameEnergyBased.lua", "b903ee64450a462c66cf803adcf3e62c9498a4617846bf6ccd9b795b7ac92182", [
            (b"\n\t\tfor name, level in pairs(self.level.sublevels) do\n", b"\n\t\tfor name, level in pairs(self.level.sublevels) do\n\t\t\tif require('rule_events').interrupted() then break end\n"),
            (b"\n\tfor i, e in pairs(arr) do\n", b"\n\tfor i, e in pairs(arr) do\n\t\tif require('rule_events').interrupted() then break end\n"),
        ]),
        ("tome/mod/class/NPC.lua", "bdc619d1ed2ee9f457e10b461789b0aae4ab8385b14c9a78ad4246af9f0644f9", [
            (b'\n\t\tself:fireTalentCheck("callbackOnActEnd")\n', b'\n\t\tself:fireTalentCheck("callbackOnActEnd")\n\t\tif require("rule_events").after_action() then break end\n'),
        ]),
    ]
    provenance = []
    for name, expected, changes in sources:
        source = runtime / name
        raw = source.read_bytes()
        if hashlib.sha256(raw).hexdigest() != expected:
            raise SystemExit(f"Unknown rule boundary source: {name}")
        projected = raw.replace(b"\r\n", b"\n")
        if name.startswith("engine/"):
            old = b"\n\t\t\t\te:act(self)\n"
            if projected.count(old) != 2:
                raise SystemExit("Unknown scheduler action sites")
            parts = projected.split(old)
            projected = (parts[0] + old + b"\t\t\t\tif require('rule_events').after_action() then break end\n"
                         + parts[1] + old + b"\t\t\t\trequire('rule_events').after_action()\n" + parts[2])
        for old, new in changes:
            if projected.count(old) != 1:
                raise SystemExit(f"Unknown rule boundary layout: {name}")
            projected = projected.replace(old, new, 1)
        target = out / "bundle" / name
        target.write_bytes(projected)
        manifest[target.relative_to(out).as_posix()] = {"sha256": digest(target), "bytes": len(projected)}
        provenance.append({"source": name, "source_sha256": expected, "projection_sha256": digest(target),
                           "changes": [{"before": a.decode(), "after": b.decode()} for a, b in changes],
                           "complete_action_hooks": ["global_entity_after_act", "level_entity_after_act"] if name.startswith("engine/") else ["npc_after_callbackOnActEnd"]})
    (out / "rule-boundary-projection.json").write_text(json.dumps(provenance, indent=2), encoding="utf-8")


def project_native_save_uid(runtime, out, manifest):
    """Preserve saved IDs during explicitly scoped native object loading."""
    source = runtime / 'engine/engine/Entity.lua'
    raw = checked(source, '4c9eb3873ad9f99ffd01ab75a44faaf219a6dc1393dbf0a30584a9288f2141d2')
    anchor = 'local next_uid = 1'
    extension = """local next_uid = 1
local native_uid_restore = false
local native_uid_max = 0
function _M.native_uid_state() return next_uid end
function _M.native_uid_begin_restore()
 assert(not native_uid_restore, 'nested UID restore')
 native_uid_restore = true
 native_uid_max = 0
end
function _M.native_uid_end_restore(next_value)
 assert(native_uid_restore and type(next_value)=='number' and next_value==math.floor(next_value) and next_value>0, 'invalid UID restore state')
 assert(next_value>native_uid_max, 'UID high water mark is not above restored entities')
 next_uid = next_value
 native_uid_restore = false
end
"""
    original = """function _M:loaded()
	local ouid = self.uid
	if __uids[self.uid] and __uids[self.uid] == self.uid then __uids[self.uid] = nil end
	self.uid = next_uid
	__uids[self.uid] = self
	next_uid = next_uid + 1"""
    patched = """function _M:loaded()
	local ouid = self.uid
	if native_uid_restore then
		assert(type(self.uid)=='number' and self.uid==math.floor(self.uid) and self.uid>0 and not __uids[self.uid], 'invalid or duplicate restored UID')
		__uids[self.uid] = self
		if self.uid>native_uid_max then native_uid_max=self.uid end
	else
		if __uids[self.uid] and __uids[self.uid] == self.uid then __uids[self.uid] = nil end
		self.uid = next_uid
		__uids[self.uid] = self
		next_uid = next_uid + 1
	end"""
    if raw.count(anchor) != 1 or raw.count(original) != 1:
        raise SystemExit('Unknown native Entity UID lifecycle')
    projected = raw.replace(anchor, extension, 1).replace(original, patched, 1)
    target = out / 'bundle/engine/engine/Entity.lua'
    target.write_text(projected, encoding='utf-8', newline='')
    manifest[target.relative_to(out).as_posix()] = {'sha256': digest(target), 'bytes': target.stat().st_size}
    (out / 'native-uid-projection.json').write_text(json.dumps({'source_sha256': digest(source), 'projection_sha256': digest(target)}, indent=2), encoding='utf-8')


def project_native_save_class(runtime, out, manifest):
    """Allow original class.load to resolve native plain-table fragments."""
    source = runtime / 'engine/engine/class.lua'
    raw = checked(source, 'e65f81d273090e02c29855d1d5b0b0452878399f7d6a8bd024ef3ec6fc498928')
    anchor = '\t\tloadstring = loadstring,\n\t\tloadObject = function(n)'
    replacement = "\t\tloadstring = loadstring,\n\t\tloadFunctionRef = function(id) return engine.Savefile.current_save:loadFunctionRef(id) end,\n\t\tloadFunction = function(code,id,fnid) return engine.Savefile.current_save:loadFunction(code,id,fnid) end,\n\t\tloadTable = function(n) return engine.Savefile.current_save:loadPlain(n) end,\n\t\tloadObject = function(n)"
    if raw.count(anchor) != 1: raise SystemExit('Unknown native class load layout')
    projected = raw.replace(anchor, replacement, 1)
    order_anchor = '\t\t\tengine.Savefile.current_save.loaded[name] = t\n'
    if projected.count(order_anchor) != 1: raise SystemExit('Unknown native setLoaded layout')
    projected = projected.replace(order_anchor, order_anchor + '\t\t\tif native_zone_order_capture then native_zone_order_capture(name, t) end\n', 1)
    clone_anchor = '\tfor k, e in pairs(d) do\n'
    if projected.count(clone_anchor) != 1: raise SystemExit('Unknown native clone layout')
    projected = projected.replace(clone_anchor, '\tfor k, e in (native_zone_order_pairs or pairs)(d) do\n', 1)
    target = out / 'bundle/engine/engine/class.lua'
    target.write_text(projected, encoding='utf-8', newline='')
    manifest[target.relative_to(out).as_posix()] = {'sha256': digest(target), 'bytes': target.stat().st_size}
    (out / 'native-class-projection.json').write_text(json.dumps({'source_sha256': digest(source), 'projection_sha256': digest(target)}, indent=2), encoding='utf-8')


def project_wanderer(runtime, out, manifest):
    source = runtime / 'tome/mod/dialogs/WandererSeed.lua'
    raw = checked(source, '574dd3d5ee49c1071ffc477c673b9e9338fd680398cda2911e64f3e5ff7df63f')
    action = raw[raw.index('function _M:makeWanderer()'):]
    seed, restore = '\trng.seed(seed)', '\trng.seed(os.time())'
    if action.count(seed) != 1 or action.count(restore) != 1:
        raise SystemExit('Unknown Wanderer RNG layout')
    # Keep the native tree/seed algorithm; restore the world RNG instead of
    # seeding future battle rules with wall-clock time.
    action = action.replace(seed, '\tlocal world_rng=rng.state_get()\n' + seed)
    action = action.replace(restore, '\trng.state_set(world_rng)')
    target = out / 'bundle/generated/native_wanderer.lua'
    license_text = raw[:raw.index('require "engine.class"')]
    target.write_text(license_text + '-- Generated from original WandererSeed.makeWanderer.\nlocal _M={}\n' + action + '\nreturn _M\n', encoding='utf-8')
    manifest[target.relative_to(out).as_posix()] = {'sha256': digest(target), 'bytes': target.stat().st_size}
    module = runtime / 'tome/mod/init.lua'
    text = module.read_text(encoding='utf-8')
    name = re.search(r'^short_name\s*=\s*"([^"]+)"', text, re.M)
    version = re.search(r'^version\s*=\s*\{(\d+),(\d+),(\d+)\}', text, re.M)
    if not name or not version:
        raise SystemExit('Unknown native module metadata layout')
    info = out / 'bundle/generated/native_module_info.lua'
    info.write_text('return {version={' + ','.join(version.groups()) + '},version_string=' + json.dumps(name[1] + '-' + '.'.join(version.groups())) + ',addons={}}\n', encoding='utf-8')
    manifest[info.relative_to(out).as_posix()] = {'sha256': digest(info), 'bytes': info.stat().st_size}
    (out / 'wanderer-projection.json').write_text(json.dumps({'source': str(source.relative_to(runtime)), 'source_sha256': digest(source),
        'module_source_sha256': digest(module), 'projection_sha256': digest(target),
        'rules': 'original makeWanderer; remove widget construction; retain original seed and tree logic',
        'rng_change': 'restore full world RNG after native local shuffle instead of rng.seed(os.time())'}, indent=2), encoding='utf-8')


def project_over_mind(runtime, out, manifest):
    """Restore the permission captured by the native Over Mind sustain."""
    name = 'tome/data/talents/psionic/thought-forms.lua'
    raw = (runtime / name).read_bytes()
    expected = '7cbcd6ff95fb4427c3b1ff3fcd486851aad8a690b75ac763853fe1f00a31188d'
    old = b'game.party:hasMember(p.target).control = old_control'
    new = b'game.party:hasMember(p.target).control = p.old_control'
    if hashlib.sha256(raw).hexdigest() != expected or raw.count(old) != 1:
        raise SystemExit('Unknown Over Mind source or permission restoration layout')
    projected = raw.replace(old, new, 1)
    target = out / 'bundle' / name
    target.write_bytes(projected)
    manifest[target.relative_to(out).as_posix()] = {'sha256': digest(target), 'bytes': len(projected)}
    (out / 'over-mind-projection.json').write_text(json.dumps({'source': name, 'source_sha256': expected,
        'projection': target.relative_to(out).as_posix(), 'projection_sha256': digest(target),
        'before': old.decode(), 'after': new.decode()}, indent=2) + '\n', encoding='utf-8')


def native_content_libraries():
    expected = {
        'luamd5/md5.c': 'f09df761bc376849fcef98892c771b751a0a3bc1291def281d9292d6b18b399e',
        'luamd5/md5lib.c': 'd75c52796da23883f952b79aa2fa3ae92341caf6a65ba333cafdf481f75e2e61',
        'luasocket/mime.c': 'bb2d1fdc5be9a838ca2908c369472acdc4ffac60e26d252b16b03b8eeb3fb69e',
        'libtcod_import/noise_c.c': '3f2bd63e9dc54eb6b1789e334b5fff1ba8cbd0084ab68df0f683de66531dc540',
    }
    for name, identity in expected.items():
        checked(SRC / name, identity)
    return [SRC / name for name in expected]


def prepare_noise(generated):
    source = checked(SRC / 'noise.c', '29d1b6ab906f451186cccdd75a1d369bab5f8fbf86c0871c72b07fa4db0a3573')
    # The upstream binding also contains OpenGL texture methods. Only the
    # numerical binding is needed by rules in the headless worker.
    core = source[:source.index('#define BYTES_PER_TEXEL')]
    registration = source[source.index('static const struct luaL_Reg noiselib'):]
    excluded = ('#include "display.h"', '#include "script.h"', '{"makeTexture')
    pure = '\n'.join(line for line in (core + registration).splitlines()
                     if not any(key in line for key in excluded))
    (generated / 'pure_noise.c').write_text(pure + '\n', encoding='utf-8')


def prepare(out):
    generated = out / "generated"
    generated.mkdir(parents=True, exist_ok=True)
    prepare_noise(generated)
    addon = ADDON / "superload/mod/class/Player.lua"
    checked(addon, "97c501f50a730b08e18f680e548191559ece9d65f1aa246668b27ba66fb8aa97")
    (generated / "aioo_source.inc").write_text(
        "static const unsigned char aioo_source[] = {" + ",".join(map(str, addon.read_bytes())) + "};\n", encoding="ascii")
    core = checked(SRC / "core_lua.c", "9006a07b9ba0581d916e5e2f2e2f2f287aa9964710e82137ddac0039497d8f04")
    includes = '''#include <stdio.h>
#include <math.h>
#include <stdint.h>
#include <string.h>
#include <time.h>
#include <stdlib.h>
#include "lua.h"
#include "lauxlib.h"
#include "auxiliar.h"
#include "types.h"
#include "SFMT.h"
'''
    methods = core[core.index("static int rng_float("):core.index("static int lua_zlib_compress(")]
    old = '\tstatic bool stored = FALSE;\n\tstatic double z0;\n\tstatic double z1;'
    seed_tail = '\t\tinit_gen_rand(time(NULL));\n\treturn 0;'
    if methods.count(old) != 1 or methods.count(seed_tail) != 1:
        raise SystemExit("Unknown native RNG source layout")
    methods = methods.replace(old, '\tdouble z0;').replace(seed_tail, '\t\tinit_gen_rand(time(NULL));\n\tstored = FALSE; z1 = 0;\n\treturn 0;')
    methods = 'static bool stored = FALSE;\nstatic double z1 = 0;\n' + methods
    methods += (ROOT / "tome_mvp/headless/rng_state.c.inc").read_text(encoding="utf-8")
    (generated / "pure_core.c").write_text(core[:core.index("#include")] + includes + methods + '''
int open_pure(lua_State *L){
 auxiliar_newclass(L,"core{line}",line_reg); luaL_openlib(L,"rng",rnglib,0);
 luaL_openlib(L,"bresenham",linelib,0); lua_settop(L,0); init_gen_rand(1);
 lua_getglobal(L,"rng"); lua_pushcfunction(L,rng_state_get); lua_setfield(L,-2,"state_get");
 lua_pushcfunction(L,rng_state_set); lua_setfield(L,-2,"state_set"); lua_pop(L,1); return 0;
}
''', encoding="utf-8")
    sfmt = checked(SRC / "SFMT.c", "3009ae758bcc6f4e9b055f3f3d26827c4c5a2f950de6d8cbd1b058fa8ec1c6a3")
    (generated / "pure_sfmt.c").write_text(sfmt + "\n" + (ROOT / "tome_mvp/headless/sfmt_state.c.inc").read_text(encoding="utf-8"), encoding="utf-8")
    subprocess.run([sys.executable, str(ROOT / "tome_mvp/headless/prepare_fov.py"), str(SRC / "fov.c"), str(generated / "pure_fov.c")], check=True)
    subprocess.run([sys.executable, str(ROOT / "tome_mvp/headless/prepare_bootstrap.py"), str(generated)], check=True)
    # Preserve loader precedence from the native host. Only Lua rules are
    # packaged; no credentials, saves, logs, source tree or game artwork.
    runtime = RUNTIME
    inputs = {
        "headless": ROOT / "tome_mvp/headless", "generated": generated,
        "tome": runtime / "tome", "engine": runtime / "engine",
        "thirdparty": runtime / "installation/game/thirdparty",
        "game": runtime / "installation/game",
    }
    manifest = {}
    for name, source in inputs.items():
        for p in sorted(source.rglob("*.lua")):
            rel = p.relative_to(source)
            if name == "headless" and ("probe" in p.stem or "fixture" in p.stem):
                continue
            target = out / "bundle" / name / rel
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(p, target)
            manifest[target.relative_to(out).as_posix()] = {"sha256": digest(target), "bytes": target.stat().st_size}
    project_tactical_ai(runtime, out, manifest)
    project_rule_boundaries(runtime, out, manifest)
    project_native_save_uid(runtime, out, manifest)
    project_native_save_class(runtime, out, manifest)
    project_wanderer(runtime, out, manifest)
    project_over_mind(runtime, out, manifest)
    return generated, manifest


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, default=ROOT / "artifacts/tome-wasm-20261111/mvp")
    parser.add_argument("--sdk", type=Path, default=SDK)
    parser.add_argument("--native-worker", type=Path, default=ROOT / "artifacts/tome-input-20261111/full-candidate/worker_host.exe")
    parser.add_argument("--prepare-only", action="store_true")
    parser.add_argument("--encounter", type=Path, help="Validated tome-encounter-v1 JSON; immutable for this build")
    parser.add_argument("--party-bootstrap", action="store_true", help="trusted host only")
    parser.add_argument("--experimental-native-snapshot", action="store_true", help="isolated test builds only; native snapshots remain under validation")
    parser.add_argument("--experimental-native-partitions", action="store_true", help="isolated test builds only; native partitions remain under validation")
    parser.add_argument("--experimental-native-warm", action="store_true", help="isolated test builds only; transaction-confirmed resident VM")
    args = parser.parse_args()
    if args.experimental_native_warm and not args.experimental_native_partitions: raise SystemExit("Warm mode requires native partitions")
    out = args.output.resolve()
    out.relative_to((ROOT / "artifacts").resolve())
    out.mkdir(parents=True, exist_ok=True)
    generated, manifest = prepare(out)
    if args.experimental_native_snapshot:
        snapshot_module = out / 'bundle/headless/native_save.lua'
        data = snapshot_module.read_text(encoding='utf-8')
        if data.count('local M={}') != 1: raise SystemExit('Unknown native snapshot gate')
        snapshot_module.write_text(data.replace('local M={}', 'local M={ready=true}', 1), encoding='utf-8')
        manifest[snapshot_module.relative_to(out).as_posix()] = {'sha256': digest(snapshot_module), 'bytes': snapshot_module.stat().st_size}
        worker = out / 'bundle/headless/worker.lua'
        data = worker.read_text(encoding='utf-8')
        old = '"methods":{"capabilities":true,'
        new = '"methods":{"snapshot_export":true,"snapshot_import":true,"capabilities":true,'
        if data.count(old) != 1: raise SystemExit('Unknown worker capability layout')
        worker.write_text(data.replace(old, new, 1), encoding='utf-8')
        manifest[worker.relative_to(out).as_posix()] = {'sha256': digest(worker), 'bytes': worker.stat().st_size}
    if args.experimental_native_partitions:
        partition_module = out / 'bundle/headless/native_partition_runtime.lua'
        data = partition_module.read_text(encoding='utf-8')
        if data.count('local M={ready=false,warm_ready=false}') != 1: raise SystemExit('Unknown native partition gate')
        target_gate = 'local M={ready=true,warm_ready=true}' if args.experimental_native_warm else 'local M={ready=true,warm_ready=false}'
        partition_module.write_text(data.replace('local M={ready=false,warm_ready=false}', target_gate, 1), encoding='utf-8')
        manifest[partition_module.relative_to(out).as_posix()] = {'sha256': digest(partition_module), 'bytes': partition_module.stat().st_size}
        worker = out / 'bundle/headless/worker.lua'
        data = worker.read_text(encoding='utf-8')
        old = '"methods":{'
        new = '"methods":{"partition_enable":true,"partition_export":true,"partition_import":true,'
        if data.count(old) != 1: raise SystemExit('Unknown worker capability layout')
        if args.experimental_native_warm: new = new + '"partition_prepare":true,"partition_confirm":true,"partition_abort":true,'
        worker.write_text(data.replace(old, new, 1), encoding='utf-8')
        manifest[worker.relative_to(out).as_posix()] = {'sha256': digest(worker), 'bytes': worker.stat().st_size}
    encounter = None
    if args.encounter:
        from tome_mvp.encounter import validate_encounter
        encounter = validate_encounter(json.loads(args.encounter.read_text(encoding='utf-8-sig')),allow_bootstrap=args.party_bootstrap)
        payload = json.dumps(encounter, ensure_ascii=False, sort_keys=True)
        delimiter = '='
        while ']' + delimiter + ']' in payload:
            delimiter += '='
        target = out / 'bundle/headless/encounter_config.lua'
        target.write_text("return assert(require('json_validate').decode([" + delimiter + '[' + payload + ']' + delimiter + ']))\n', encoding='utf-8')
        manifest[target.relative_to(out).as_posix()] = {'sha256': digest(target), 'bytes': target.stat().st_size}
        (out / 'encounter.json').write_text(payload + '\n', encoding='utf-8')
    if args.native_worker.is_file():
        # An optional native reference uses precisely the prepared rules and
        # the same 20x20 setting. It is never used as a browser fallback.
        native = out / "native-generated"
        native.mkdir(exist_ok=True)
        for p in generated.glob("*.lua"):
            shutil.copyfile(p, native / p.name)
        probe = native / "probe.lua"
        probe.write_text("TOME_SCENE_SIZE=20\n" + probe.read_text(encoding="utf-8"), encoding="utf-8")
        bundle = out / "bundle"
        argv = [args.native_worker.resolve(), out / "native-read.log", "/worker.lua", bundle / "headless", native, bundle / "tome", bundle / "engine", bundle / "thirdparty", bundle / "game"]
        (out / "native_config.json").write_text(json.dumps({"worker_argv": list(map(str, argv)), "timeout_seconds": 30, "startup_timeout_seconds": 90}, indent=2), encoding="utf-8")
    web = out / "public"
    web.mkdir(exist_ok=True)
    for name in ("index.html", "style.css", "app.js"):
        original = ROOT / "tome_mvp/web" / name
        if not original.exists():
            continue
        text = original.read_text(encoding="utf-8")
        if name == "index.html":
            text = text.replace('<script src="/app.js">', '<script src="/client.js"></script><script src="/app.js">')
            text = text.replace('<title>ToME 战斗</title>', '<title>ToME Wasm · 20×20</title>')
            text = text.replace('TO ME', 'TO ME Wasm')
            text = text.replace('id="seed" type="number" value="7"', 'id="seed" type="number" value="'+str(encounter['seed'] if encounter else 12)+'"')
        if name == "app.js":
            assert text.count('await fetch(') == 3, "Unknown web transport call sites"
            text = text.replace('await fetch(', 'await window.tomeTransport.request(')
        (web / name).write_text(text, encoding="utf-8")
    # CSS filename is an actual input, not assumed from historical snapshots.
    for p in (ROOT / "tome_mvp/web").glob("*.css"):
        shutil.copyfile(p, web / p.name)
    frozen_host_scripts = {}
    if args.experimental_native_partitions:
        host_modules = out / "host"
        host_modules.mkdir(exist_ok=True)
        host_entry_names = ["tome_partition_host.mjs", "tome_partition_migrate.mjs", "tome_partition_candidate.mjs", "tome_validate_operations.mjs"]
        if args.experimental_native_warm: host_entry_names.append("tome_partition_resident.mjs")
        for name in host_entry_names:
            text = (ROOT / "scripts" / name).read_text(encoding="utf-8")
            text = text.replace("../tome_mvp/wasm/partition_session_host.mjs", "./partition_session_host.mjs")
            text = text.replace("../tome_mvp/wasm/partition_transport.mjs", "./partition_transport.mjs")
            text = text.replace("../tome_mvp/wasm/partition_hot_codec.mjs", "./partition_hot_codec.mjs")
            text = text.replace("../tome_mvp/wasm/battle_session.mjs", "../public/battle_session.mjs")
            (host_modules / name).write_text(text, encoding="utf-8")
        host_dependency_names = ["partition_session_host.mjs", "partition_transport.mjs"]
        if args.experimental_native_warm: host_dependency_names.append("partition_hot_codec.mjs")
        for name in host_dependency_names:
            text = (ROOT / "tome_mvp/wasm" / name).read_text(encoding="utf-8")
            if name == "partition_session_host.mjs":
                text = text.replace("'./partition_session.mjs'", "'../public/partition_session.mjs'")
            if name == "partition_hot_codec.mjs":
                text = text.replace("'./battle_session.mjs'", "'../public/battle_session.mjs'")
            (host_modules / name).write_text(text, encoding="utf-8")
        public_deps = ("battle_session.mjs", "engine_bridge.mjs", "kernel_runtime.mjs", "encounter_overlay.mjs", "partition_session.mjs", "partition_transport.mjs")
        for name in public_deps:
            text = (ROOT / "tome_mvp/wasm" / name).read_text(encoding="utf-8")
            if "__TOME_BUILD_ID__" in text or "__TOME_ENCOUNTER_SEED__" in text:
                raise SystemExit("Frozen host dependency contains build placeholder")
            (web / name).write_text(text, encoding="utf-8")
        for path in [*(host_modules / name for name in [*host_entry_names, *host_dependency_names]), *(web / name for name in public_deps)]:
            frozen_host_scripts[path.relative_to(out).as_posix()] = {"sha256": digest(path), "bytes": path.stat().st_size}
    identity_inputs = {"lua": manifest, "host": digest(ROOT / "tome_mvp/wasm/host.c"), "native_serial": digest(ROOT / "tome_mvp/wasm/native_serial.c"),
                       "native_content_libraries": {str(p.relative_to(SRC)): digest(p) for p in [*native_content_libraries(), SRC / 'luamd5/md5.h', SRC / 'luasocket/mime.h', SRC / 'noise.c', SRC / 'libtcod_import/noise.h', SRC / 'libtcod_import/libtcod.h']},
                       "builder": digest(Path(__file__)), "host_scripts": frozen_host_scripts,
                       "web": {str(p.relative_to(ROOT)): digest(p) for folder in (ROOT / "tome_mvp/web", ROOT / "tome_mvp/wasm")
                               for p in sorted(folder.iterdir()) if p.is_file() and p.suffix in ('.js', '.mjs', '.html', '.css')}}
    source_identity = hashlib.sha256(json.dumps(identity_inputs, sort_keys=True).encode()).hexdigest()[:16]
    (out / "identity.json").write_text(json.dumps({"build_id": source_identity, "inputs": identity_inputs}, indent=2), encoding="utf-8")
    public_modules = ["client.js", "engine_bridge.mjs", "browser_worker.mjs", "browser_checkpoint.mjs", "character_worker.mjs", "diagnostics.mjs", "kernel_runtime.mjs", "battle_session.mjs", "encounter_overlay.mjs", "dm.html"]
    if args.experimental_native_partitions:
        public_modules.extend(["partition_transport.mjs", "partition_session.mjs"])
    for name in public_modules:
        source = ROOT / "tome_mvp/wasm" / name
        if source.exists():
            text = source.read_text(encoding="utf-8").replace('__TOME_BUILD_ID__', source_identity).replace('__TOME_ENCOUNTER_SEED__', str(encounter['seed'] if encounter else 12))
            (web / name).write_text(text, encoding="utf-8")
    for relative, descriptor in frozen_host_scripts.items():
        path = out / relative
        if digest(path) != descriptor["sha256"] or path.stat().st_size != descriptor["bytes"]:
            raise SystemExit("Frozen host dependency changed after identity calculation: " + relative)
    (web / "package.json").write_text('{"type":"module"}\n', encoding="utf-8")
    (out / "lua-manifest.json").write_text(json.dumps(manifest, indent=2), encoding="utf-8")
    if args.prepare_only:
        print(json.dumps({"prepared": str(out), "lua_files": len(manifest)}))
        return
    sdk = args.sdk.resolve()
    emcc = sdk / "upstream/emscripten/emcc.py"
    if not emcc.is_file() or not (sdk / ".emscripten").is_file():
        raise SystemExit("Missing activated local Emscripten SDK; see tome_mvp/wasm/README.md")
    env = dict(os.environ, EM_CONFIG=str(sdk / ".emscripten"), EMSDK_PYTHON=sys.executable)
    files = [p for p in sorted((SRC / "lua").glob("*.c")) if p.name != "print.c"]
    files += sorted((SRC / "lpeg").glob("*.c"))
    files += native_content_libraries()
    files += [SRC / "fov/fov.c", SRC / "auxiliar.c", SRC / "luabitop/bit.c", generated / "pure_sfmt.c", generated / "pure_core.c", generated / "pure_fov.c", generated / "pure_noise.c", ROOT / "tome_mvp/wasm/host.c", ROOT / "tome_mvp/wasm/native_serial.c"]
    command = [sys.executable, str(emcc), "-O2", "-fno-strict-aliasing", "-DMEXP=19937", "-D_USE_MATH_DEFINES", "-DM_PI=3.14159265358979323846", *["-I" + str(p) for p in (SRC / "lua", SRC / "physfs", SRC, generated)], *map(str, files), "--no-entry", "-sMODULARIZE=1", "-sEXPORT_ES6=1", "-sEXPORT_NAME=createTome", "-sENVIRONMENT=worker,node", "-sALLOW_MEMORY_GROWTH=1", "-sINITIAL_MEMORY=134217728", "-sMAXIMUM_MEMORY=1073741824", "-sSTACK_SIZE=4194304", "-sASSERTIONS=1", "-sNO_EXIT_RUNTIME=1", '-sEXPORTED_FUNCTIONS=["_tome_init","_tome_request","_tome_result","_tome_free","_malloc","_free"]', '-sEXPORTED_RUNTIME_METHODS=["cwrap","UTF8ToString","FS","HEAPU8"]', "--preload-file", str(out / "bundle") + "@/bundle", "-o", str(web / "tome.js")]
    command.insert(command.index("-O2"), "-I" + str(SRC / "libtcod_import"))
    subprocess.run(command, check=True, env=env)
    provenance = {"command": command, "sdk_commit": subprocess.check_output(["git", "-C", str(sdk), "rev-parse", "HEAD"], text=True).strip(), "scene_size": 20, "lua_files": len(manifest), "host_sha256": digest(ROOT / "tome_mvp/wasm/host.c"), "outputs": {p.name: {"bytes": p.stat().st_size, "sha256": digest(p)} for p in web.glob("tome.*")}}
    (out / "build.json").write_text(json.dumps(provenance, indent=2), encoding="utf-8")
    print(json.dumps({"public": str(web), "outputs": provenance["outputs"]}, indent=2))


if __name__ == "__main__":
    main()
