"""Generate build-only rule projections and a VFS index for the bootstrap probe."""
from pathlib import Path
import hashlib
import json
import shutil
import sys

ROOT = Path(__file__).resolve().parents[2]
BASE = ROOT / "artifacts/tome-headless-build-20261109"
RUNTIME = BASE / "runtime"
OUT = Path(sys.argv[1]) if len(sys.argv) > 1 else BASE / "windows-build"
load = RUNTIME / "tome/mod/load.lua"
raw = load.read_bytes()
if hashlib.sha256(raw).hexdigest() != "e8ed64f78cfab8e5091ca6c6b64fa7dfe759dc1ba7e43c4bd191a329052703eb":
    raise SystemExit("Unexpected upstream mod/load.lua hash")
OUT.mkdir(parents=True, exist_ok=True)
shutil.copyfile(ROOT / "tome_mvp/headless/bootstrap.lua", OUT / "probe.lua")
roots = [RUNTIME / "tome", RUNTIME / "engine", RUNTIME / "installation/game/thirdparty", RUNTIME / "installation/game"]
directories = {}
for root in roots:
    for path in root.rglob("*.lua"):
        parts = path.relative_to(root).parts
        for n, name in enumerate(parts):
            directories.setdefault("/" + "/".join(parts[:n]), set()).add(name)
rows = ["return {"]
for directory, names in sorted(directories.items()):
    rows.append("[" + json.dumps(directory, ensure_ascii=False) + "] = {" + ",".join(json.dumps(name, ensure_ascii=False) for name in sorted(names)) + "},")
(OUT / "directories.lua").write_text("\n".join(rows + ["}"]), encoding="utf-8")
intervals = [(1, 19), (61, 63), (66, 73), (77, 77), (116, 165), (167, 207), (228, 239), (292, 295)]
lines = raw.decode("utf-8").splitlines()
# The upstream hash fixes the exact source. These checks document the projected
# native equipment layouts and fail if the selected span stops covering them.
assert lines[139] == "ActorInventory.equipdolls = {"
assert "alchemist_golem = {" in lines[157]
assert lines[164] == "}"
(OUT / "rules.lua").write_text("\n".join(line if any(a <= i <= b for a, b in intervals) else "" for i, line in enumerate(lines, 1)), encoding="utf-8")
