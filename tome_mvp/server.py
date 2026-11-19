"""Independent HTTP shell for an injected ToME candidate service."""
from __future__ import annotations

import argparse
import json
import socket
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Protocol
from urllib.parse import unquote, urlsplit


class GameService(Protocol):
    def observe(self) -> dict: ...
    def command(self, payload: dict) -> dict: ...
    def close(self) -> None: ...


WEB = Path(__file__).parent / "web"
NATIVE_ASSETS = Path(__file__).resolve().parents[1] / "artifacts" / "tome-formal-squad-20261111" / "assets"
MAX_BODY = 16384
SOCKET_TIMEOUT = 5


def strict_json(data):
    def unique_pairs(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError("duplicate key")
            result[key] = value
        return result
    def reject_constant(value):
        raise ValueError("non-finite number")
    return json.loads(data, object_pairs_hook=unique_pairs, parse_constant=reject_constant)
ASSETS = {"/": ("index.html", "text/html; charset=utf-8"),
          "/app.js": ("app.js", "text/javascript; charset=utf-8"),
          "/style.css": ("style.css", "text/css; charset=utf-8")}


def create_server(service: GameService, port: int = 0) -> ThreadingHTTPServer:
    lock = threading.RLock()
    revision = 0
    control_epoch = 0
    ai_authorized = False
    navigation_authorized = False
    ai_remaining = 0
    ai_control_reason = None

    class Handler(BaseHTTPRequestHandler):
        def setup(self):
            super().setup()
            self.connection.settimeout(SOCKET_TIMEOUT)

        def log_message(self, format, *args):
            pass

        def reply(self, status, body, kind="application/json; charset=utf-8"):
            if not isinstance(body, bytes):
                body = json.dumps(body, ensure_ascii=False).encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", kind)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.end_headers()
            self.wfile.write(body)

        def reject_post(self, status, body):
            # Send the rejection before bounded draining. On Windows, closing a
            # socket with an unread request body can discard the error response.
            raw = json.dumps(body, ensure_ascii=False).encode("utf-8")
            self.close_connection = True
            self.send_response(status)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(raw)))
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(raw)
            self.wfile.flush()
            try:
                self.connection.shutdown(socket.SHUT_WR)
            except OSError:
                return
            values = self.headers.get_all("Content-Length", [])
            length = int(values[0]) if len(values) == 1 and values[0].isascii() and values[0].isdigit() and len(values[0]) <= 8 else MAX_BODY + 1
            remaining = min(length, MAX_BODY + 1)
            deadline = time.monotonic() + 0.5
            try:
                while remaining > 0:
                    left = deadline - time.monotonic()
                    if left <= 0:
                        break
                    self.connection.settimeout(left)
                    chunk = self.rfile.read1(min(4096, remaining))
                    if not chunk:
                        break
                    remaining -= len(chunk)
            except (OSError, TimeoutError, ValueError):
                pass

        def do_GET(self):
            path = urlsplit(self.path)
            if path.query or path.fragment:
                return self.reply(404, {"error": "unknown path"})
            if path.path == "/api/state":
                if self.headers.get("Host") != f"127.0.0.1:{self.server.server_port}":
                    return self.reply(403, {"error": "invalid host"})
                with lock:
                    try:
                        state = dict(service.observe())
                        state["revision"] = revision
                        state["control_epoch"] = control_epoch
                        state["ai_remaining"] = ai_remaining
                        state["ai_control_reason"] = ai_control_reason
                        status, body = 200, state
                    except Exception:
                        status, body = 500, {"error": "原生服务不可用，战斗状态未知"}
                return self.reply(status, body)
            if path.path.startswith('/assets/'):
                if self.headers.get('Host') != f'127.0.0.1:{self.server.server_port}':
                    return self.reply(403, {'error': 'invalid host'})
                try:
                    relative = unquote(path.path[len('/assets/'):], encoding='utf-8', errors='strict')
                    parts = relative.split('/')
                    if (not relative.startswith('data/gfx/') or not relative.endswith('.png') or
                            any(not p or p in ('.', '..') or '\\' in p or ':' in p or '%' in p or '\x00' in p for p in parts)):
                        raise ValueError('invalid asset path')
                    root = NATIVE_ASSETS.resolve(strict=True)
                    asset = (root / Path(*parts)).resolve(strict=True)
                    asset.relative_to(root)
                    manifest = strict_json((root / 'manifest.json').read_text(encoding='utf-8'))
                    if not isinstance(manifest, dict) or manifest.get('version') != 1 or not isinstance(manifest.get('assets'), dict) or relative not in manifest['assets'] or not asset.is_file():
                        raise ValueError('asset not listed')
                    return self.reply(200, asset.read_bytes(), 'image/png')
                except (OSError, ValueError, UnicodeError, json.JSONDecodeError):
                    return self.reply(404, {'error': 'unknown asset'})
            if path.path not in ASSETS:
                return self.reply(404, {"error": "unknown path"})
            filename, kind = ASSETS[path.path]
            self.reply(200, (WEB / filename).read_bytes(), kind)

        def do_POST(self):
            nonlocal revision, control_epoch, ai_authorized, ai_remaining, ai_control_reason, navigation_authorized
            if self.path != "/api/command":
                return self.reject_post(404, {"error": "unknown path"})
            origin = self.headers.get("Origin")
            expected = f"http://127.0.0.1:{self.server.server_port}"
            if origin != expected or self.headers.get("Host") != expected[7:]:
                return self.reject_post(403, {"error": "same origin required"})
            if self.headers.get("Transfer-Encoding") is not None:
                return self.reject_post(400, {"error": "transfer encoding unsupported"})
            if self.headers.get_content_type() != "application/json":
                return self.reject_post(415, {"error": "JSON required"})
            try:
                values = self.headers.get_all("Content-Length", [])
                if len(values) != 1 or not values[0].isascii() or not values[0].isdigit() or len(values[0]) > 8:
                    return self.reject_post(400, {"error": "invalid body"})
                length = int(values[0])
                if length < 1 or length > MAX_BODY:
                    return self.reject_post(400, {"error": "invalid body"})
                data = strict_json(self.rfile.read(length))
                if not isinstance(data, dict) or type(data.get("revision")) is not int:
                    raise ValueError()
            except (ValueError, UnicodeDecodeError, TimeoutError):
                return self.reply(400, {"error": "invalid body"})
            with lock:
                action = data.get("type")
                if action != "pause" and data["revision"] != revision:
                    status, body = 409, {"error": "stale revision", "revision": revision, "control_epoch": control_epoch}
                elif action == "ai_step" and (not ai_authorized or type(data.get("control_epoch")) is not int or data["control_epoch"] != control_epoch):
                    status, body = 409, {"error": "stale control epoch", "revision": revision, "control_epoch": control_epoch}
                elif action == "navigate_step" and (not navigation_authorized or type(data.get("control_epoch")) is not int or data["control_epoch"] != control_epoch):
                    status, body = 409, {"error": "stale control epoch", "revision": revision, "control_epoch": control_epoch}
                elif action == "rescue_step" and (type(data.get("control_epoch")) is not int or data["control_epoch"] != control_epoch):
                    status, body = 409, {"error": "stale control epoch", "revision": revision, "control_epoch": control_epoch}
                elif action == "ai_start" and (not {"type", "revision", "budget"}.issubset(data) or
                        set(data) - {"type", "revision", "budget", "mode"} or
                        type(data.get("budget")) is not int or not 1 <= data["budget"] <= 500 or
                        ("mode" in data and (type(data["mode"]) is not str or data["mode"] not in ("sweep", "explore", "rest")))):
                    status, body = 400, {"error": "AI budget must be an integer from 1 to 500", "revision": revision, "control_epoch": control_epoch}
                else:
                    try:
                        payload = {k: v for k, v in data.items() if k not in {"revision", "control_epoch"}}
                        capability = payload.get("mode") if action == "attack" else action
                        allowed = {"move", "navigate_start", "navigate_step", "wait", "melee", "ranged", "talent", "ai_start", "ai_step", "ai_config", "ai_template_save", "ai_template_load", "pause", "new_game", "save", "load", "continue_pending", "takeover", "return_control", "rescue_start", "rescue_step", "rescue_cancel", "confirm_down"}
                        observed = service.observe()
                        caps = observed.get("capabilities", {})
                        if observed.get("ai_status") == "running" and action in {"ai_config", "ai_template_save", "ai_template_load"}:
                            if action == "ai_config":
                                from .service import validate_ai_config
                                validate_ai_config({k: v for k, v in payload.items() if k != "type"})
                            elif set(payload) != {"type"}:
                                raise ValueError("template command takes no parameters")
                            control_epoch += 1
                            ai_authorized = False
                            ai_remaining = 0
                            if not isinstance(caps, dict) or caps.get("pause") is not True:
                                raise ValueError("cannot stop AI for configuration")
                            service.command({"type": "pause"})
                            caps = service.observe().get("capabilities", {})
                        if capability not in allowed or (action == "attack" and capability not in {"melee", "ranged"}) or (action != "attack" and action in {"melee", "ranged"}) or not isinstance(caps, dict) or caps.get(capability) is not True:
                            # A valid, current load request is a takeover even if
                            # the fixed slot is absent. Do not leave an old AI
                            # loop authorized after the user asked to restore.
                            if action == "load" and set(payload) == {"type"}:
                                control_epoch += 1
                                ai_authorized = False
                                ai_remaining = 0
                                if isinstance(caps, dict) and caps.get("pause") is True:
                                    service.command({"type": "pause"})
                                revision += 1
                            status, body = 403, {"error": "unsupported command", "revision": revision, "control_epoch": control_epoch}
                        else:
                            # A takeover invalidates all previously authorized AI loops,
                            # even if the native command later returns an error.
                            if action not in {"ai_step", "rescue_step", "navigate_step"}:
                                control_epoch += 1
                                ai_authorized = False
                                navigation_authorized = False
                                ai_remaining = 0
                                ai_control_reason = None
                            native_payload = ({"type": "pause"} if action == "pause" else
                                              {k: v for k, v in payload.items() if k != "budget"})
                            result = dict(service.command(native_payload))
                            if result.get("down_events") and action == "rescue_step":
                                control_epoch += 1
                                ai_authorized = False
                                ai_remaining = 0
                                ai_control_reason = "party_down"
                            if action == "pause":
                                ai_control_reason = "user_pause"
                            if action == "navigate_start" and result.get("navigation", {}).get("status") == "running":
                                navigation_authorized = True
                            if action == "navigate_step" and result.get("navigation", {}).get("status") != "running":
                                navigation_authorized = False
                                control_epoch += 1
                            if action == "ai_start" and result.get("ai_status") == "running":
                                ai_authorized = True
                                ai_remaining = data["budget"]
                            if action == "ai_step":
                                ai_remaining -= 1
                                if result.get("ai_status") != "running" or result.get("advance_status") in ("input", "await_input", "terminal"):
                                    ai_authorized = False
                                    ai_remaining = 0
                                    ai_control_reason = "native_stop"
                                    control_epoch += 1
                                elif ai_remaining == 0:
                                    # The accepted action is never replayed. Stop
                                    # before responding, even if the client leaves.
                                    ai_authorized = False
                                    control_epoch += 1
                                    result = dict(service.command({"type": "pause", "reason": "budget"}))
                                    if result.get("ai_status") != "stopped":
                                        raise RuntimeError("budget stop was not confirmed")
                                    ai_control_reason = "budget_exhausted"
                            revision += 1
                            result["revision"] = revision
                            result["control_epoch"] = control_epoch
                            result["ai_remaining"] = ai_remaining
                            result["ai_control_reason"] = ai_control_reason
                            status, body = 200, result
                    except (ValueError, KeyError) as exc:
                        navigation_authorized = False
                        ai_authorized = False
                        ai_remaining = 0
                        control_epoch += 1
                        revision += 1
                        status, body = 400, {"error": str(exc), "revision": revision, "control_epoch": control_epoch}
                    except Exception:
                        # A native operation may have changed state before failing.
                        record = getattr(service, 'record_failure', None)
                        if callable(record):
                            record()
                        navigation_authorized = False
                        ai_authorized = False
                        ai_remaining = 0
                        control_epoch += 1
                        revision += 1
                        status, body = 500, {"error": "内核未确认操作结果；自动授权已撤销，内核状态未知", "revision": revision, "control_epoch": control_epoch}
            return self.reply(status, body)

    server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    server.daemon_threads = True
    return server


def main():
    parser = argparse.ArgumentParser(description="ToME candidate experiment")
    parser.add_argument("--port", type=int, default=8910)
    parser.add_argument("--session", default="default")
    parser.add_argument("--seed", type=int, default=7)
    parser.add_argument("--backend", choices=("headless", "desktop"), default="headless")
    parser.add_argument("--config", help="headless worker JSON configuration")
    parser.add_argument("--fixture", choices=("formal", "rescue"), help="explicit isolated scenario")
    args = parser.parse_args()
    # The native adapter is intentionally supplied by the integration owner.
    from .service import create_service
    service = create_service(session=args.session, seed=args.seed, backend=args.backend, config=args.config, fixture=args.fixture)
    server = None
    try:
        server = create_server(service, args.port)
        print(f"http://127.0.0.1:{server.server_port}/", flush=True)
        server.serve_forever()
    finally:
        if server is not None:
            server.server_close()
        service.close()


if __name__ == "__main__":
    main()
