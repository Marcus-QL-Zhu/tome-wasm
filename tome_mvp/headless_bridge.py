"""Bounded, persistent JSON-lines transport for a ToME headless worker."""
from __future__ import annotations

import json
import io
import os
import queue
import subprocess
import threading
import time
from pathlib import Path

from .native.job import close_owned_job, popen_owned

PROTOCOL = "tome-headless-v1"
MAX_LINE = 2 * 1024 * 1024
MAX_STDERR = 16384
# act may itself consume up to 30 ticks; reserve at most 300 further ticks.
MAX_DRAIN_TICKS = 300
DRAIN_BATCH_TICKS = 100


class WorkerError(RuntimeError):
    pass


class WorkerRejected(ValueError):
    pass


def _strict_json(raw):
    def pairs(items):
        result = {}
        for key, value in items:
            if key in result:
                raise ValueError("duplicate response key")
            result[key] = value
        return result
    def constant(_):
        raise ValueError("non-finite response number")
    return json.loads(raw, object_pairs_hook=pairs, parse_constant=constant)


def load_config(path):
    data = _strict_json(Path(path).read_text(encoding="utf-8-sig"))
    if not isinstance(data, dict):
        raise ValueError("headless config must be an object")
    argv = data.get("worker_argv")
    if not isinstance(argv, list) or not argv or any(not isinstance(x, str) or not x or "\x00" in x for x in argv):
        raise ValueError("worker_argv must be a nonempty string array")
    timeout = data.get("timeout_seconds", 20)
    startup = data.get("startup_timeout_seconds", 90)
    if any(type(x) not in (int, float) or not 0 < x <= 300 for x in (timeout, startup)):
        raise ValueError("timeouts must be in (0, 300]")
    return argv, float(timeout), float(startup)


class HeadlessBridge:
    def __init__(self, argv, timeout=20, startup_timeout=90):
        self.argv = list(argv)
        self.timeout = timeout
        self.startup_timeout = startup_timeout
        self.process = None
        self.generation = None
        self.seq = 0
        self.lock = threading.Lock()
        self.operation_lock = threading.RLock()
        self.responses = queue.Queue(maxsize=2)
        self.worker_capabilities = {}
        self.stderr_tail = bytearray()
        self.stderr_lock = threading.Lock()
        self.threads = []
        self.writer = None
        self.stdout_reader = None
        self.pending = False
        self.boundary = "decision"
        self.ai_status = "idle"
        self.ai_stop_reason = None
        self.ai_epoch = None
        self.input_request = None

    def start(self, seed=7, empty=False, fixture=None):
        if type(seed) is not int or not 0 <= seed <= 2147483647:
            raise ValueError("seed must be a nonnegative 31-bit integer")
        if fixture not in (None, "formal", "rescue", "skill_types", "ranged_policy", "exploration", "recovery") or (empty and fixture is not None):
            raise ValueError("invalid engineering fixture")
        if self.process is not None:
            raise RuntimeError("bridge already started")
        self.process = popen_owned(self.argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE, shell=False, bufsize=0,
                              **({"start_new_session": True} if os.name != "nt" else {"creationflags": subprocess.CREATE_NO_WINDOW}))
        self.stdout_reader = io.BufferedReader(self.process.stdout, buffer_size=64 * 1024)
        self.threads = [threading.Thread(target=self._read_responses, daemon=True),
                        threading.Thread(target=self._read_stderr, daemon=True)]
        for thread in self.threads:
            thread.start()
        try:
            caps = self.request("capabilities", timeout=self.startup_timeout)
            if not isinstance(caps, dict) or caps.get("protocol") != PROTOCOL:
                raise WorkerError("incompatible worker protocol")
            self.worker_capabilities = caps
            if empty:
                return None
            params = {"seed": seed}
            if fixture is not None:
                params["fixture"] = fixture
            created = self.request("create", params, timeout=self.startup_timeout)
            self._set_generation(created)
            self._receipt(created)
            return self.observe()
        except BaseException:
            self.close()
            raise

    def _read_stderr(self):
        try:
            while True:
                data = self.process.stderr.read(4096)
                if not data:
                    return
                with self.stderr_lock:
                    self.stderr_tail.extend(data)
                    del self.stderr_tail[:-MAX_STDERR]
        except (OSError, ValueError):
            return

    def _read_responses(self):
        try:
            while True:
                line = self.stdout_reader.readline(MAX_LINE + 1)
                if not line:
                    self.responses.put_nowait(WorkerError("worker stdout closed"))
                    return
                if len(line) > MAX_LINE or not line.endswith(b"\n"):
                    self.responses.put_nowait(WorkerError("worker response exceeds limit or is incomplete"))
                    return
                self.responses.put_nowait(line)
        except Exception:
            try:
                self.responses.put_nowait(WorkerError("worker response stream failed"))
            except queue.Full:
                pass

    def request(self, method, params=None, expected_generation=None, timeout=None):
        wait = self.timeout if timeout is None else timeout
        deadline = time.monotonic() + wait
        if not self.lock.acquire(timeout=wait):
            raise TimeoutError("worker bridge busy; request was not sent")
        try:
            return self._request_locked(method, params, expected_generation, deadline)
        finally:
            self.lock.release()

    def _request_locked(self, method, params, expected_generation, deadline):
        if self.process is None or self.process.poll() is not None:
            raise WorkerError("worker unavailable")
        self.seq += 1
        request = {"protocol": PROTOCOL, "id": self.seq, "method": method, "params": params or {}}
        if expected_generation is not None:
            request["expected_generation"] = expected_generation
        raw = (json.dumps(request, ensure_ascii=False, allow_nan=False, separators=(",", ":")) + "\n").encode("utf-8")
        if len(raw) > MAX_LINE:
            raise ValueError("worker request exceeds limit")
        written = queue.Queue(maxsize=1)
        def write():
            try:
                self.process.stdin.write(raw)
                self.process.stdin.flush()
                written.put_nowait(None)
            except Exception as exc:
                written.put_nowait(exc)
        writer = threading.Thread(target=write, daemon=True)
        self.writer = writer
        writer.start()
        try:
            error = written.get(timeout=max(0, deadline - time.monotonic()))
            if error is not None:
                raise WorkerError("worker input failed; outcome unknown")
            line = self.responses.get(timeout=max(0, deadline - time.monotonic()))
            if isinstance(line, Exception):
                raise line
            reply = _strict_json(line)
            if not isinstance(reply, dict) or type(reply.get("id")) is not int or reply["id"] != self.seq or type(reply.get("ok")) is not bool:
                raise WorkerError("invalid worker response; outcome unknown")
            if reply["ok"]:
                if "result" not in reply or "error" in reply:
                    raise WorkerError("invalid worker result; outcome unknown")
                return reply["result"]
            if "error" not in reply or "result" in reply:
                raise WorkerError("invalid worker error; outcome unknown")
            error = reply["error"]
            if isinstance(error, dict) and error.get("outcome") == "unknown" and self.process is not None:
                # Native fatal replies are followed by worker shutdown. Give
                # it a bounded opportunity to flush its original traceback.
                try:
                    self.process.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    pass
                if isinstance(error.get("code"), str) and error['code']:
                    raise WorkerError(f"worker {error['code']}; outcome unknown")
            if not isinstance(error, dict) or not isinstance(error.get("code"), str) or not error["code"] or error.get("outcome") != "rejected":
                raise WorkerError("invalid worker rejection; outcome unknown")
            raise WorkerRejected(error["code"])
        except WorkerRejected:
            raise
        except Exception as exc:
            self.close()
            if isinstance(exc, queue.Empty):
                raise TimeoutError("worker deadline exceeded; worker terminated; outcome unknown") from exc
            raise WorkerError("worker protocol failed; worker terminated; outcome unknown") from exc

    def _set_generation(self, result):
        generation = result.get("generation") if isinstance(result, dict) and result.get("accepted") is True else None
        if type(generation) is not int or generation < 0:
            self.close()
            raise WorkerError("worker did not return a valid generation")
        self.generation = generation

    def observe(self):
        with self.operation_lock:
            return self._observe_locked()

    def _observe_locked(self):
        result = self.request("observe")
        if not isinstance(result, dict) or type(result.get("generation")) is not int or result["generation"] != self.generation:
            self.close()
            raise WorkerError("invalid observation generation")
        result = dict(result)
        # The worker identifies the actual scenario; no other fixture is
        # presented as the source-based formal encounter.
        result["scene_kind"] = "formal" if result.get("fixture") == "formal" else "engineering"
        # Only explicit web-command declarations enable UI controls.
        declared = self.worker_capabilities.get("web_commands", {})
        observed = result.get("capabilities", {})
        if not isinstance(declared, dict) or not isinstance(observed, dict):
            declared, observed = {}, {}
        result["capabilities"] = {key: declared.get(key) is True and observed.get(key) is True
                                  for key in ("move", "navigate_start", "navigate_step", "wait", "melee", "ranged", "talent", "ai_step", "pause", "new_game", "save", "load", "takeover", "return_control", "rescue_start", "rescue_step", "rescue_cancel", "confirm_down")}
        methods = self.worker_capabilities.get("methods", {})
        # Plain improved_tactical is not the Player AIoo Custom integration.
        result["capabilities"]["ai_step"] &= self.worker_capabilities.get("ai_provider") == "player_aioo_custom"
        # The service supplies a fixed local slot and owns restore replacement.
        result["capabilities"]["save"] = isinstance(methods, dict) and methods.get("save") is True and not self.pending and result.get("save_unavailable_reason") is None
        result["capabilities"]["load"] = isinstance(methods, dict) and methods.get("restore") is True and not self.pending
        # The worker has no autonomous clock. Pause is a local control-epoch
        # takeover followed by read-only observation, not a native action.
        result["capabilities"]["pause"] = isinstance(methods, dict) and methods.get("observe") is True
        result["capabilities"]["continue_pending"] = self.pending and isinstance(methods, dict) and methods.get("advance") is True
        for key in ("ai_status", "ai_stop_reason", "ai_epoch"):
            if key in result:
                setattr(self, key, result[key])
            else:
                result[key] = getattr(self, key)
        result["capabilities"]["ai_start"] = (declared.get("ai_start") is True and observed.get("ai_start") is True and self.worker_capabilities.get("ai_provider") == "player_aioo_custom" and self.boundary == "decision")
        result["capabilities"]["ai_config"] = (declared.get("ai_config") is True and self.boundary == "decision" and
                                                 (observed.get("ai_config") is True or result.get("ai_status") == "running"))
        modes = self.worker_capabilities.get("ai_modes", result.get("ai_modes"))
        if isinstance(modes, list) and all(isinstance(mode, str) and mode in ("sweep", "explore", "rest") for mode in modes):
            result["capabilities"]["ai_modes"] = list(modes)
        if result.get("down_events"):
            result["capabilities"]["load"] = False
        result["advance_status"] = self.boundary
        if self.input_request is not None:
            result["input_request"] = self.input_request
        if self.boundary in ("pending", "input", "await_input", "terminal"):
            for key in ("move", "navigate_start", "navigate_step", "wait", "melee", "ranged", "talent", "ai_step"):
                result["capabilities"][key] = False
        if self.boundary in ("pending", "terminal"):
            result["capabilities"]["save"] = False
            result["capabilities"]["load"] = False
        return result

    def _receipt(self, result):
        if (not isinstance(result, dict) or result.get("accepted") is not True
                or type(result.get("generation")) is not int or result["generation"] != self.generation
                or result.get("boundary") not in ("decision", "input", "await_input", "terminal", "pending")):
            self.close()
            raise WorkerError("invalid worker receipt; outcome unknown")
        self.pending = result["boundary"] == "pending"
        self.boundary = result["boundary"]
        self.input_request = result.get("input_request") if self.boundary in ("input", "await_input") else None
        for key in ("ai_status", "ai_stop_reason", "ai_epoch"):
            if key in result:
                setattr(self, key, result[key])

    def _drain(self, deadline):
        methods = self.worker_capabilities.get("methods", {})
        if not isinstance(methods, dict) or methods.get("advance") is not True:
            return
        remaining = MAX_DRAIN_TICKS
        while self.pending and remaining > 0:
            left = deadline - time.monotonic()
            if left <= 0:
                break
            budget = min(DRAIN_BATCH_TICKS, remaining)
            self._receipt(self.request("advance", {"budget": budget}, self.generation, timeout=left))
            # The worker does not report exact consumption; account for the full
            # requested budget, even when it reaches a boundary earlier.
            remaining -= budget

    def command(self, payload):
        with self.operation_lock:
            return self._command_locked(payload)

    def _command_locked(self, payload):
        kind = payload.get("type")
        observed = self.observe()
        caps = observed["capabilities"]
        cap = payload.get("mode") if kind == "attack" else kind
        if caps.get(cap) is not True:
            raise ValueError("unsupported command")
        methods = self.worker_capabilities.get("methods", {})
        if kind == "pause":
            if isinstance(methods, dict) and methods.get("ai_stop") is True and not self.pending and not observed.get("rescue_progress") and not observed.get("down_events"):
                reason = payload.get("reason", "user")
                if reason not in ("user", "budget"):
                    raise ValueError("invalid stop reason")
                self._receipt(self.request("act", {"type": "ai_stop", "reason": reason}, self.generation))
                if self.boundary != "decision":
                    self.close()
                    raise WorkerError("AI stop did not reach decision boundary; outcome unknown")
            return self.observe()
        if kind == "continue_pending":
            self._drain(time.monotonic() + self.timeout)
            return self.observe()
        if kind == "new_game":
            seed = payload.get("seed", 7)
            if type(seed) is not int or not 0 <= seed <= 2147483647:
                raise ValueError("invalid seed")
            result = self.request("reset", {"seed": seed}, self.generation, self.startup_timeout)
            old = self.generation
            self._set_generation(result)
            if self.generation <= old:
                self.close()
                raise WorkerError("reset did not advance generation")
            self._receipt(result)
        else:
            if kind not in ("ai_step", "ai_start", "navigate_step") and not observed.get("rescue_progress") and not observed.get("down_events") and isinstance(methods, dict) and methods.get("ai_stop") is True:
                self._receipt(self.request("act", {"type": "ai_stop"}, self.generation))
                if self.boundary != "decision":
                    self.close()
                    raise WorkerError("AI stop did not reach decision boundary; outcome unknown")
            if kind == "ai_step":
                native_payload = {"type": "native_ai", "ai_epoch": self.ai_epoch}
            elif kind == "ai_start":
                if set(payload) - {"type", "mode"} or ("mode" in payload and
                        (type(payload["mode"]) is not str or payload["mode"] not in ("sweep", "explore", "rest"))):
                    raise ValueError("invalid automation mode")
                if "mode" in payload and payload["mode"] not in self.worker_capabilities.get("ai_modes", []):
                    raise ValueError("unsupported automation mode")
                native_payload = dict(payload)
            elif kind == "ai_config":
                native_payload = {"type": "ai_config", "config": {k: v for k, v in payload.items() if k != "type"}}
            elif kind == "navigate_start":
                if set(payload) != {"type", "x", "y"} or type(payload.get("x")) is not int or type(payload.get("y")) is not int:
                    raise ValueError("invalid navigation target")
            elif kind == "navigate_step":
                if set(payload) != {"type"}:
                    raise ValueError("unexpected navigation parameters")
            elif kind == "move":
                dx, dy = payload.get("dx"), payload.get("dy")
                if type(dx) is not int or type(dy) is not int or max(abs(dx), abs(dy)) != 1:
                    raise ValueError("move requires adjacent integer delta")
            elif kind == "attack":
                target = payload.get("target")
                if not isinstance(target, (str, int)) or isinstance(target, bool) or not str(target).isdigit():
                    raise ValueError("attack requires a visible target id")
            elif kind == "talent":
                talent = payload.get("talent")
                if not isinstance(talent, str) or not talent or len(talent) > 128:
                    raise ValueError("invalid talent id")
                target = payload.get("target")
                if target is not None and (isinstance(target, bool) or not isinstance(target, (str, int)) or not str(target).isdigit()):
                    raise ValueError("invalid target id")
                if "x" in payload or "y" in payload:
                    if target is not None or type(payload.get("x")) is not int or type(payload.get("y")) is not int:
                        raise ValueError("invalid grid target")
            elif kind in ("takeover", "rescue_start"):
                target = payload.get("target")
                if isinstance(target, bool) or not isinstance(target, (str, int)) or not str(target).isdigit():
                    raise ValueError("invalid party target id")
            elif kind == "confirm_down":
                if set(payload) != {"type", "event_id", "generation"} or type(payload.get("event_id")) is not int or payload["event_id"] < 1 or type(payload.get("generation")) is not int or payload["generation"] != self.generation:
                    raise ValueError("invalid down event")
            elif kind in ("return_control", "rescue_step", "rescue_cancel"):
                if set(payload) != {"type"}:
                    raise ValueError("unexpected parameters")
            elif kind != "wait":
                raise ValueError("unsupported command")
            if kind not in ("ai_step", "ai_start", "ai_config"):
                native_payload = dict(payload)
            deadline = time.monotonic() + self.timeout
            self._receipt(self.request("act", native_payload, self.generation, timeout=self.timeout))
            if kind != "confirm_down":
                self._drain(deadline)
        return self.observe()

    def close(self):
        process = self.process
        if process is None:
            return
        if os.name != "nt":
            # Kill the isolated owned group while its leader PID is protected
            # from reaping; then collect the worker process.
            close_owned_job(process)
            try:
                process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=2)
        else:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=2)
            close_owned_job(process)
        # Drain the exited worker's diagnostic pipe before closing it. Closing
        # first can discard the traceback that explains an unknown outcome.
        for thread in self.threads:
            if thread is not threading.current_thread():
                thread.join(timeout=1)
        for stream in (process.stdin, self.stdout_reader, process.stdout, process.stderr):
            if stream is not None:
                stream.close()
        if self.writer is not None and self.writer is not threading.current_thread():
            self.writer.join(timeout=1)
        self.threads.clear()
