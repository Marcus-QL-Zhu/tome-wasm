"""Extract only explicitly referenced ToME PNGs from the local Steam archives."""
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import zipfile

INSTALL = Path(r"C:\Program Files (x86)\Steam\steamapps\common\TalesMajEyal")
OUTPUT = Path("artifacts/tome-formal-squad-20261111/assets")
ARCHIVES = ("game/modules/tome-gfx.team", "game/modules/tome.team", "game/engines/te4-1.7.6.teae")
HUD = ("data/gfx/ui/playerframe/back.png", "data/gfx/ui/minimap/back.png",
       "data/gfx/ui/hotkeys/back.png", "data/gfx/ui/message-log.png",
       "data/gfx/ui/resources/back.png", "data/gfx/ui/resources/front_life.png",
       "data/gfx/ui/resources/front_stamina.png", "data/gfx/ui/resources/front_hate.png")


def safe_name(value):
    if not isinstance(value, str) or "\\" in value or ":" in value:
        raise ValueError(f"invalid image path: {value!r}")
    p = PurePosixPath(value)
    if p.is_absolute() or ".." in p.parts or not value.startswith("data/gfx/") or p.suffix.lower() != ".png":
        raise ValueError(f"invalid image path: {value!r}")
    return p.as_posix()


def output_path(name, root=OUTPUT):
    name = safe_name(name)
    root = root.resolve()
    target = root.joinpath(*PurePosixPath(name).parts).resolve()
    if not target.is_relative_to(root):
        raise ValueError(f"image path escapes output: {name!r}")
    return target


def references(value):
    if isinstance(value, dict):
        for key, item in value.items():
            if key in ("image", "icon") and isinstance(item, str) and item.startswith("data/gfx/"):
                yield safe_name(item)
            else:
                yield from references(item)
    elif isinstance(value, list):
        for item in value:
            yield from references(item)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--state", type=Path, action="append", default=[], help="Observer JSON or JSONL")
    parser.add_argument("--asset", action="append", default=[], help="Exact data/gfx/...png")
    parser.add_argument("--talent-map", type=Path, help="Native talent icon inventory")
    args = parser.parse_args()
    names = set(HUD)
    names.update(map(safe_name, args.asset))
    for source in args.state:
        raw = source.read_text(encoding="utf-8")
        try:
            values = [json.loads(raw)]
        except json.JSONDecodeError:
            values = [json.loads(line) for line in raw.splitlines() if line.strip()]
        for value in values:
            names.update(references(value))
    if args.talent_map:
        for line in args.talent_map.read_text(encoding="utf-8").splitlines():
            fields = line.split("\t")
            if len(fields) >= 2 and fields[0] == "TALENT_ICON":
                names.add(safe_name("data/gfx/talents/" + fields[1]))

    OUTPUT.mkdir(parents=True, exist_ok=True)
    manifest_path = OUTPUT / "manifest.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8")) if manifest_path.exists() else {"version": 1, "assets": {}}
    archives = [(name, zipfile.ZipFile(INSTALL / name)) for name in ARCHIVES]
    try:
        for name in sorted(names):
            matches = [(archive, z.read(name)) for archive, z in archives if name in z.namelist()]
            if not matches:
                raise FileNotFoundError(name)
            if len({sha(data) for _, data in matches}) != 1:
                raise ValueError(f"ambiguous source: {name}")
            archive, data = matches[0]
            target = output_path(name)
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
            manifest["assets"][name] = {"sha256": sha(data), "source_archive": archive, "source_member": name}
    finally:
        for _, z in archives:
            z.close()
    manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"{len(names)} requested; {len(manifest['assets'])} total PNGs; {manifest_path}")


if __name__ == "__main__":
    main()
