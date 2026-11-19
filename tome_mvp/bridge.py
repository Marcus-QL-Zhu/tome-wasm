"""Bounded file bridge to a private ToME process."""
import json
import os
import threading
import time
from pathlib import Path
from .launch import DEFAULT_INSTALL, launch
from .native.job import close_owned_job


class NativeBridge:
    def __init__(self, session_root, install=DEFAULT_INSTALL, timeout=20, startup_timeout=90):
        self.session_root = Path(session_root).absolute()
        self.install = Path(install)
        self.timeout = timeout
        self.startup_timeout = startup_timeout
        self.process = None
        self.seq = 0
        self.lock = threading.Lock()
        self.last_snapshot = None

    def start(self, seed=7):
        if type(seed) is not int or not 0 <= seed <= 2147483647:
            raise ValueError("seed must be a nonnegative 31-bit integer")
        if self.process is not None:
            raise RuntimeError("bridge already started")
        self.process = launch(self.session_root, self.install, seed)
        try:
            return self._exchange("observe", timeout=self.startup_timeout)
        except BaseException:
            self.close()
            raise

    def _exchange(self, operation, arg1="", arg2="", timeout=None):
        if self.process is None or self.process.poll() is not None:
            raise RuntimeError("native process unavailable")
        self.seq += 1
        seq = self.seq
        settings = self.session_root / "user" / "isolated" / "4.0" / "settings"
        temp = settings / "bridge-command.tmp"
        temp.write_text(f"{seq}|{operation}|{arg1}|{arg2}\n", encoding="utf-8")
        os.replace(temp, settings / "bridge-command.cfg")
        deadline = time.monotonic() + (timeout if timeout is not None else self.timeout)
        response = settings / "bridge-response.cfg"
        while time.monotonic() < deadline:
            if self.process.poll() is not None:
                raise RuntimeError("native process exited during command")
            if response.exists():
                raw = response.read_text(encoding="utf-8", errors="replace").strip()
                parts = raw.split("|", 3)
                if len(parts) == 4 and parts[0] == str(seq) and parts[3] == "END":
                    if parts[1] == "blocked_danger":
                        self.last_snapshot = json.loads(parts[2])
                        raise ValueError("automatic action blocked by danger")
                    if parts[1] not in ("ok", "rejected"):
                        self.close()
                        raise RuntimeError("native command failed: " + parts[1])
                    result = json.loads(parts[2])
                    self.last_snapshot = result
                    if parts[1] == "rejected":
                        raise ValueError("native action rejected")
                    return result
            time.sleep(0.05)
        self.close()
        raise TimeoutError("native command timed out; process terminated and outcome is unknown")

    def observe(self):
        if not self.lock.acquire(timeout=self.timeout):
            raise TimeoutError("native bridge is busy")
        try:
            return self._exchange("observe")
        finally:
            self.lock.release()

    def command(self, payload):
        if not self.lock.acquire(timeout=self.timeout):
            raise TimeoutError("native bridge is busy")
        try:
            return self._command_locked(payload)
        finally:
            self.lock.release()

    def _command_locked(self, payload):
        kind = payload.get("type")
        if kind == "new_game":
            seed = payload.get("seed", 7)
            if type(seed) is not int or not 0 <= seed <= 2147483647:
                raise ValueError("seed must be a nonnegative 31-bit integer")
            return self._exchange("new_game", seed, timeout=self.startup_timeout)
        if kind in ("wait", "pause"):
            return self._exchange(kind)
        if kind == "ai_step":
            return self._exchange("ai_step")
        if kind == "attack":
            if payload.get("mode", "melee") != "melee":
                raise NotImplementedError("ranged attack is not verified")
            target = str(payload.get("target", ""))
            if not target.isdigit():
                raise ValueError("attack requires a visible target id")
            return self._exchange("attack", target)
        if kind == "move":
            dx, dy = payload.get("dx"), payload.get("dy")
            if type(dx) is not int or type(dy) is not int or max(abs(dx),abs(dy)) != 1:
                raise ValueError("move requires adjacent integer delta")
            return self._exchange("move", dx, dy)
        raise NotImplementedError(f"native command not verified: {kind}")

    def close(self):
        if self.process is not None and self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=5)
            except Exception:
                self.process.kill()
                self.process.wait(timeout=5)
        if self.process is not None:
            close_owned_job(self.process)

if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser(description="Run a bounded isolated ToME scene probe")
    parser.add_argument("session_root", type=Path)
    parser.add_argument("--seed", type=int, default=7)
    parser.add_argument("--command", action="append", default=[], help="JSON command, may be repeated")
    args = parser.parse_args()
    bridge = NativeBridge(args.session_root)
    try:
        print(json.dumps(bridge.start(args.seed), ensure_ascii=False), flush=True)
        for item in args.command:
            print(json.dumps(bridge.command(json.loads(item)), ensure_ascii=False), flush=True)
    finally:
        bridge.close()
