"""Mount installed Ashes and Embers rule scripts in a separate, local Wasm probe."""
import argparse
from collections import defaultdict
import hashlib
import json
from pathlib import Path, PurePosixPath
import shutil
from zipfile import ZipFile

from prepare_tome_headless_runtime import INSTALL

PACKS = ("ashes-urhrok", "orcs")  # Native addon weights 2 and 10.


def prepare(base, output, install):
    if output.exists():
        raise FileExistsError(output)
    files = {}
    sources = {}
    dirs = defaultdict(set)
    for name in PACKS:
        archive = install / "game/dlcs" / (name + ".teaac")
        with archive.open("rb") as stream:
            sources[name] = hashlib.file_digest(stream, "sha256").hexdigest()
        with ZipFile(archive) as z:
            for member in z.namelist():
                prefix = "tome-" + name + "/"
                if not member.startswith(prefix) or not member.endswith(".lua"):
                    continue
                parts = PurePosixPath(member[len(prefix):]).parts
                if any(part in ("..", "/") or "\\" in part or ":" in part for part in parts):
                    raise ValueError(member)
                if parts[0] == "overload":
                    dest = parts[1:]
                elif parts[0] == "data":
                    dest = ("data-" + name, *parts[1:])
                elif parts[0] in ("superload", "hooks"):
                    dest = ("mod", "addons", name, *parts)
                else:
                    continue
                for index, part in enumerate(dest):
                    dirs["/" + "/".join(dest[:index])].add(part)
                files["/bundle/tome/" + "/".join(dest)] = z.read(member).decode("utf-8-sig")
    loader = (install / "game/loader/init.lua").read_text(encoding="utf8")
    start = loader.index("__addons_fn_superloads = {}")
    end = loader.index("table.insert(package.loaders, 2, te4_loader)", start)
    # Only modules with an actual superload need the additional native searcher.
    # Keep the existing frozen loader for ordinary modules and headless overrides.
    supers = sorted({p.split("/superload/")[1][:-4].replace("/", ".") for p in files if "/superload/" in p})
    bootstrap = ("__addons_superload_order=" + lua_array(PACKS) + "\n" + loader[start:end]
                 + "\nlocal supers={};for _,n in ipairs(" + lua_array(supers)
                 + ")do supers[n]=true end\ntable.insert(package.loaders,2,function(n) if supers[n] then return te4_loader(n) end end)\n")
    hooks = "\n".join(f'dofile("/mod/addons/{name}/hooks/load.lua")' for name in PACKS)
    directories = "return {\n" + ",\n".join("[" + json.dumps(p) + "]=" + lua_array(sorted(v))
                        for p, v in sorted(dirs.items())) + "\n}"
    files["/bundle/headless/dlc_directories.lua"] = directories
    files["/bundle/headless/dlc_loader.lua"] = bootstrap
    files["/bundle/headless/dlc_hooks.lua"] = hooks
    public = output / "public"
    shutil.copytree(base / "public", public)
    shutil.copytree(base / "host", output / "host")
    shutil.copyfile(base / "build.json", output / "build.json")
    rules = Path(__file__).with_name("tome_dlc_probe_mount.mjs").read_text(encoding="utf8")
    module = "const files=" + json.dumps(files, ensure_ascii=True) + ";\n" + rules
    module = module.replace("export function mountDlc(", "function mountDlc(", 1)
    runtime = public / "kernel_runtime.mjs"
    src = runtime.read_text(encoding="utf8")
    anchor = " if(hooks.prepare)await hooks.prepare(mod);"
    if src.count(anchor) != 1:
        raise ValueError("unknown Wasm prepare order")
    runtime.write_text(module + "\n" +
                       src.replace(anchor, " mountDlc(mod);\n" + anchor), encoding="utf8")
    identity = json.loads((base / "identity.json").read_text(encoding="utf8"))
    material = identity["inputs"]
    raw = runtime.read_bytes()
    material["host_scripts"]["public/kernel_runtime.mjs"] = {"sha256": hashlib.sha256(raw).hexdigest(), "bytes": len(raw)}
    material["installed_dlc"] = sources
    build_id = hashlib.sha256(json.dumps(material, sort_keys=True).encode()).hexdigest()[:16]
    worker = public / "browser_worker.mjs"
    worker.write_text(worker.read_text(encoding="utf8").replace(identity["build_id"], build_id), encoding="utf8")
    identity["build_id"] = build_id
    (output / "identity.json").write_text(json.dumps(identity, indent=2), encoding="utf8")
    print(build_id)


def lua_array(items):
    return "{" + ",".join(json.dumps(i) for i in items) + "}"


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--install", type=Path, default=INSTALL)
    args = parser.parse_args()
    prepare(args.base, args.output, args.install)
