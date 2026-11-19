"""Copy Lua and text rules from an installed ToME 1.7.6, without assets or DLC."""
import hashlib
import json
import os
import sys
from pathlib import Path, PurePosixPath
import zipfile

from tome_build_paths import RUNTIME
INSTALL = Path(os.environ.get("TOME_INSTALL", r"C:\Program Files (x86)\Steam\steamapps\common\TalesMajEyal"))
DEST = RUNTIME
PACKS = {"engine": "game/engines/te4-1.7.6.teae", "tome": "game/modules/tome.team", "boot": "game/modules/boot-te4.team"}
SUFFIXES = {".lua", ".txt", ".tmx", ".chat"}


def sha(data):
    return hashlib.sha256(data).hexdigest()


def main():
    if sys.argv[1:] == ["--thirdparty-only"]:
        extract_thirdparty()
        return
    if DEST.exists() and any(DEST.iterdir()):
        raise SystemExit(f"Refusing to overwrite nonempty destination: {DEST}")
    DEST.mkdir(parents=True, exist_ok=True)
    sources, entries = [], []
    for label, relative in PACKS.items():
        source = INSTALL / relative
        with source.open("rb") as stream:
            digest = hashlib.file_digest(stream, "sha256").hexdigest()
        sources.append({"path": relative, "sha256": digest})
        with zipfile.ZipFile(source) as archive:
            for info in archive.infolist():
                parts = PurePosixPath(info.filename).parts
                if info.is_dir() or PurePosixPath(info.filename).suffix.lower() not in SUFFIXES:
                    continue
                if not parts or PurePosixPath(info.filename).is_absolute() or "\\" in info.filename or any(p in (".", "..") or ":" in p for p in parts):
                    raise ValueError(f"Unsafe member {info.filename}")
                data = archive.read(info)
                target = DEST / label / Path(*parts)
                target.parent.mkdir(parents=True, exist_ok=True)
                with target.open("xb") as output:
                    output.write(data)
                entries.append({"source": relative, "member": info.filename, "path": target.relative_to(DEST).as_posix(), "bytes": len(data), "sha256": sha(data)})
    for relative in ("COPYING", "bootstrap/boot.lua", "game/loader/init.lua", "game/loader/pre-init.lua"):
        data = (INSTALL / relative).read_bytes()
        target = DEST / "installation" / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
        sources.append({"path": relative, "sha256": sha(data)})
        entries.append({"source": relative, "path": target.relative_to(DEST).as_posix(), "bytes": len(data), "sha256": sha(data)})
    (DEST / "runtime-manifest.json").write_text(json.dumps({"installation": str(INSTALL), "sources": sources, "files": entries}, indent=2) + "\n", encoding="utf-8")
    extract_thirdparty()
    print(f"Extracted {len(entries)} rule/text files; {sum(x['bytes'] for x in entries)} bytes.")


def extract_thirdparty():
    origin = INSTALL / "game/thirdparty"
    target_root = DEST / "installation/game/thirdparty"
    if target_root.exists():
        raise SystemExit(f"Refusing to overwrite: {target_root}")
    entries = []
    for source in sorted(origin.rglob("*")):
        if not source.is_file() or not (source.suffix.lower() in {".lua", ".txt"} or source.name.upper() in {"LICENSE", "COPYING"}):
            continue
        data = source.read_bytes()
        target = target_root / source.relative_to(origin)
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
        entries.append({"source": source.relative_to(INSTALL).as_posix(), "path": target.relative_to(DEST).as_posix(), "bytes": len(data), "sha256": sha(data)})
    (DEST / "thirdparty-manifest.json").write_text(json.dumps(entries, indent=2) + "\n", encoding="utf-8")
    print(f"Extracted {len(entries)} third-party Lua and license files.")


if __name__ == "__main__":
    main()
