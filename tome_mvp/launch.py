"""Isolated T-Engine bootstrap; does not create or simulate a combat scene."""
from __future__ import annotations

import subprocess
import shutil
import time
from pathlib import Path
from .native.job import popen_owned

ARTIFACT_ROOT = (Path(__file__).resolve().parent.parent / "artifacts" / "tome-native-20261109").resolve()
MARKER = ".tome-native-session"

DEFAULT_INSTALL = Path(r"C:\Program Files (x86)\Steam\steamapps\common\TalesMajEyal")


def prepare_host(session_root: Path, install: Path = DEFAULT_INSTALL, seed: int = 7) -> Path:
    supplied = Path(session_root).absolute()
    root = supplied.resolve()
    install = Path(install).resolve()
    if root == ARTIFACT_ROOT or ARTIFACT_ROOT not in root.parents:
        raise ValueError("session root must be below the dedicated artifact root")
    # Reject symlinks/junctions, including ancestors already present.
    for component in (supplied, *supplied.parents):
        if component.exists() and (component.is_symlink() or component.resolve() != component):
            raise ValueError("session path must not contain redirects")
        if component == ARTIFACT_ROOT:
            break
    if root.exists() and any(root.iterdir()):
        raise ValueError("refusing nonempty session directory; create a new session")
    root.mkdir(parents=True, exist_ok=True)
    with (root / MARKER).open("x", encoding="utf-8") as marker:
        marker.write("tome-native-session-v1\n")
    path = str(root / "user")
    if "]]" in path:
        raise ValueError("session path cannot contain ]]")
    host = root / "host"
    (host / "bootstrap").mkdir(parents=True, exist_ok=True)
    (host / "loader").mkdir(parents=True, exist_ok=True)
    (root / "user").mkdir(parents=True, exist_ok=True)
    settings = root / "user" / "isolated" / "4.0" / "settings"
    settings.mkdir(parents=True, exist_ok=True)
    if type(seed) is not int or not 0 <= seed <= 2147483647:
        raise ValueError("seed must be a nonnegative 31-bit integer")
    (settings / "bridge-seed.cfg").write_text(str(seed) + "\n", encoding="utf-8")
    (settings / "disable_all_connectivity.cfg").write_text("disable_all_connectivity = true\n", encoding="utf-8")
    (settings / "tome.gfx.cfg").write_text('tome.gfx = {tiles="ascii", size="16x16"}\n', encoding="utf-8")
    boot = (install / "bootstrap" / "boot.lua").read_text(encoding="utf-8")
    anchor = 'print("Booting T-Engine from: "'
    if anchor not in boot:
        raise RuntimeError("unsupported bootstrap format")
    boot = boot.replace(anchor, f'function fs.getUserPath() return [[{path}]] end\nfunction fs.getHomePath() return [[isolated]] end\n' + anchor, 1)
    host_path = str(host)
    if "]]" in host_path:
        raise ValueError("host path cannot contain ]]")
    boot += f'\nfs.mount([[{host_path}]], "/", false)\nfs.setPathAllowed([[{host_path}]], true)\n'
    addon_source = Path(__file__).parent / "native" / "addon"
    shutil.copytree(addon_source, host / "addons" / "tome-isolated-bridge-probe", dirs_exist_ok=True)
    (host / "bootstrap" / "boot.lua").write_text(boot, encoding="utf-8")
    loader = (install / "game" / "loader" / "init.lua").read_text(encoding="utf-8")
    if 'load(...)' not in loader:
        raise RuntimeError("unsupported loader format")
    loader = loader.replace('load(...)', 'load("te4", "LATEST", "tome", "bridge", true)', 1)
    loader = loader.replace('dofile("/engine/init.lua")', 'core.steam = nil\ndofile("/engine/init.lua")', 1)
    (host / "loader" / "init.lua").write_text(loader, encoding="utf-8")
    return host


def launch(session_root: Path, install: Path = DEFAULT_INSTALL, seed: int = 7) -> subprocess.Popen:
    host = prepare_host(session_root, install, seed)
    flags = subprocess.CREATE_NO_WINDOW if hasattr(subprocess, "CREATE_NO_WINDOW") else 0
    return popen_owned([str(Path(install) / "t-engine.exe")], cwd=host, creationflags=flags)


def wait_for_module(process: subprocess.Popen, host: Path, timeout: float = 45.0) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError(f"T-Engine exited: {process.returncode}")
        log = host / "te4_log.txt"
        if log.exists() and "[MODULE LOADER] done loading module\tTales of Maj'Eyal" in log.read_text(encoding="utf-8", errors="replace"):
            return True
        time.sleep(0.2)
    return False
