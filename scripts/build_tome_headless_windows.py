"""Build the bounded Windows bootstrap experiment from verified upstream sources."""
from pathlib import Path
import hashlib
import json
import subprocess
import argparse

ROOT = Path(__file__).resolve().parents[1]
from tome_build_paths import SOURCE, RUNTIME, ADDON, TCC
BASE = ROOT / "artifacts/tome-headless-build-20261109"
SRC = SOURCE / "src"
OUT = BASE / "windows-build"
CORE_HASH = "9006a07b9ba0581d916e5e2f2e2f2f287aa9964710e82137ddac0039497d8f04"


def main():
    global OUT
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, default=OUT)
    OUT = parser.parse_args().output.resolve()
    OUT.mkdir(parents=True, exist_ok=True)
    if not TCC.is_file() or hashlib.sha256(TCC.read_bytes()).hexdigest() != "dd48c81f436f554d8117e37776138b3ceb69a0c3aba173ac1e1aabb5464f9174":
        raise SystemExit("Expected portable tccbox==2025.10.27 compiler missing or changed")
    addon = (ADDON / 'superload/mod/class/Player.lua').read_bytes()
    if hashlib.sha256(addon).hexdigest() != '97c501f50a730b08e18f680e548191559ece9d65f1aa246668b27ba66fb8aa97':
        raise SystemExit('Unexpected Player AIoo source hash')
    (OUT / 'aioo_source.inc').write_text('static const unsigned char aioo_source[] = {' + ','.join(str(b) for b in addon) + '};\n', encoding='ascii')
    raw = (SRC / "core_lua.c").read_bytes()
    if hashlib.sha256(raw).hexdigest() != CORE_HASH:
        raise SystemExit("Unexpected upstream core_lua.c hash")
    core = raw.decode("utf-8")
    includes = '#include <stdio.h>\n#include <math.h>\n#include <stdint.h>\n#include <string.h>\n#include <time.h>\n#include <stdlib.h>\n#include "lua.h"\n#include "lauxlib.h"\n#include "auxiliar.h"\n#include "types.h"\n#include "SFMT.h"\n'
    methods = core[core.index("static int rng_float("):core.index("static int lua_zlib_compress(")]
    old = '\tstatic bool stored = FALSE;\n\tstatic double z0;\n\tstatic double z1;'
    if methods.count(old) != 1:
        raise SystemExit('Unexpected Box-Muller layout')
    methods = methods.replace(old, '\tdouble z0;')
    seed_tail = '\t\tinit_gen_rand(time(NULL));\n\treturn 0;'
    if methods.count(seed_tail) != 1:
        raise SystemExit('Unexpected rng.seed layout')
    methods = methods.replace(seed_tail, '\t\tinit_gen_rand(time(NULL));\n\tstored = FALSE; z1 = 0;\n\treturn 0;')
    methods = 'static bool stored = FALSE;\nstatic double z1 = 0;\n' + methods
    methods += (ROOT / "tome_mvp/headless/rng_state.c.inc").read_text(encoding="utf-8")
    (OUT / "pure_core.c").write_text(core[:core.index("#include")] + includes + methods + '\nint open_pure(lua_State *L){ auxiliar_newclass(L,"core{line}",line_reg); luaL_openlib(L,"rng",rnglib,0); luaL_openlib(L,"bresenham",linelib,0); lua_settop(L,0); init_gen_rand(1); lua_getglobal(L,"rng"); lua_pushcfunction(L,rng_state_get); lua_setfield(L,-2,"state_get"); lua_pushcfunction(L,rng_state_set); lua_setfield(L,-2,"state_set"); lua_pop(L,1); return 0; }\n', encoding="utf-8")
    subprocess.run(["python", str(ROOT / "tome_mvp/headless/prepare_fov.py"), str(SRC / "fov.c"), str(OUT / "pure_fov.c")], check=True)
    subprocess.run(["python", str(ROOT / "tome_mvp/headless/prepare_bootstrap.py"), str(OUT)], check=True)
    flags = ["-DMEXP=19937", "-D_USE_MATH_DEFINES", "-DM_PI=3.14159265358979323846", "-I" + str(SRC / "lua"), "-I" + str(SRC / "physfs"), "-I" + str(SRC), "-I" + str(OUT)]
    files = [f for f in sorted((SRC / "lua").glob("*.c")) if f.name != "print.c"] + sorted((SRC / "lpeg").glob("*.c"))
    sfmt_raw = (SRC / "SFMT.c").read_bytes()
    if hashlib.sha256(sfmt_raw).hexdigest() != "3009ae758bcc6f4e9b055f3f3d26827c4c5a2f950de6d8cbd1b058fa8ec1c6a3":
        raise SystemExit("Unexpected upstream SFMT.c hash")
    sfmt = sfmt_raw.decode("utf-8")
    (OUT / "pure_sfmt.c").write_text(sfmt + "\n" + (ROOT / "tome_mvp/headless/sfmt_state.c.inc").read_text(encoding="utf-8"), encoding="utf-8")
    files += [SRC / "fov/fov.c", SRC / "auxiliar.c", SRC / "luabitop/bit.c", OUT / "pure_sfmt.c", OUT / "pure_core.c", OUT / "pure_fov.c"]
    for name in ("bootstrap_probe", "worker_host"):
        subprocess.run([str(TCC), *flags, "-o", str(OUT / (name + ".exe")), *map(str, files), str(ROOT / "tome_mvp/headless" / (name + ".c"))], check=True)
        print(OUT / (name + ".exe"))
    runtime = RUNTIME
    argv = [OUT / "worker_host.exe", OUT / "worker-read.log", "/worker.lua", ROOT / "tome_mvp/headless", OUT, runtime / "tome", runtime / "engine", runtime / "installation/game/thirdparty", runtime / "installation/game"]
    config = {"worker_argv": list(map(str, argv)), "timeout_seconds": 20, "startup_timeout_seconds": 90}
    (OUT / "worker_config.json").write_text(json.dumps(config, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
