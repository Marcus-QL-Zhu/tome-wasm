"""Factory for the isolated native candidate bridge, when available."""
from pathlib import Path
import importlib
import json
import os
import tempfile
import re
import time
import math

def validate_ai_config(config):
    if not isinstance(config, dict) or set(config) != {'stop_on_rare', 'stop_enemy_count', 'talent_weights'}:
        raise ValueError('invalid AI configuration')
    if type(config['stop_on_rare']) is not bool or type(config['stop_enemy_count']) is not int or not 0 <= config['stop_enemy_count'] <= 100:
        raise ValueError('invalid AI stop settings')
    weights = config['talent_weights']
    if not isinstance(weights, dict) or len(weights) > 512:
        raise ValueError('invalid AI talent weights')
    for key, value in weights.items():
        if not isinstance(key, str) or not re.fullmatch(r'T_[A-Z0-9_]{1,120}', key) or type(value) not in (int, float) or not math.isfinite(value) or not 0 <= value <= 10:
            raise ValueError('invalid AI talent weight')
    return config

class OfflineService:
    def observe(self):
        return {"online": False, "message": "原生桥尚未接通。当前没有可运行场景。", "capabilities": {}, "map": [], "party": [], "enemies": [], "events": []}
    def command(self, payload):
        raise ValueError("原生桥尚未接通")
    def close(self):
        pass

class ServiceAdapter:
    """Project native snapshots without deriving game outcomes."""
    def __init__(self, bridge, engineering_observe_only=False, save_session=None):
        self.bridge = bridge
        self.started = time.monotonic()
        self.engineering_observe_only = engineering_observe_only
        self.save_session = save_session

    def _snapshot(self, value):
        snapshot = dict(value)
        if self.engineering_observe_only:
            snapshot["capabilities"] = {key: False for key in snapshot.get("capabilities", {})}
        if self.save_session is not None:
            caps = snapshot.get("capabilities", {})
            if isinstance(caps, dict) and caps.get("load") is True:
                caps["load"] = self._slot_path().is_file()
            if isinstance(caps, dict) and caps.get("ai_config") is True:
                caps["ai_template_save"] = True
                caps["ai_template_load"] = self._template_path().is_file()
        snapshot.setdefault("events", [])
        snapshot.setdefault("elapsed_ms", round((time.monotonic() - self.started) * 1000))
        return snapshot

    def observe(self):
        try:
            return self._snapshot(self.bridge.observe())
        except Exception:
            process = self.bridge.process
            methods = self.bridge.worker_capabilities.get('methods', {})
            if (self.save_session is None or process is None or process.poll() is None
                    or not isinstance(methods, dict) or methods.get('restore') is not True):
                raise
            # The last state is not evidence of the unknown outcome. Only an
            # explicit restore from the fixed slot remains available.
            slot = self._slot_path()
            return self._snapshot({'online':False, 'message':('原生内核不可用，操作结果未知；可从存档恢复' if slot.is_file() else '原生内核不可用，操作结果未知；无可用存档'),
                                   'generation':self.bridge.generation, 'map':[], 'party':[],
                                   'enemies':[], 'events':[], 'capabilities':{'load':slot.is_file()}})

    def record_failure(self, bridge=None):
        """Keep a bounded worker stderr tail for an unknown outcome."""
        if self.save_session is None:
            return
        bridge = bridge or self.bridge
        try:
            slot = self._slot_path()
            slot.parent.mkdir(parents=True, exist_ok=True)
            slot = self._slot_path()
            diagnostic = slot.parent / ('last-restore-error.log' if bridge is not self.bridge else 'last-worker-error.log')
            if diagnostic.is_symlink():
                return
            with bridge.stderr_lock:
                data = bytes(bridge.stderr_tail[-16384:])
            diagnostic.write_bytes(data)
        except (OSError, ValueError, AttributeError):
            pass

    def _slot_path(self):
        root = Path(__file__).resolve().parent.parent
        parts = [root / 'artifacts', root / 'artifacts' / 'tome-control-saves',
                 root / 'artifacts' / 'tome-control-saves' / self.save_session]
        if any(p.is_symlink() for p in parts):
            raise ValueError('save path must not contain symlinks')
        slot = parts[-1] / 'slot.json'
        if slot.is_symlink():
            raise ValueError('save slot must not be a symlink')
        return slot

    def _template_path(self):
        slot = self._slot_path()
        path = slot.parent / 'ai-template.json'
        if path.is_symlink():
            raise ValueError('template must not be a symlink')
        return path

    def _template(self, action):
        from .headless_bridge import _strict_json
        path = self._template_path()
        if action == 'ai_template_save':
            # Stop first; a saved template is the currently applied configuration.
            state = self.bridge.command({'type': 'pause'})
            config = state.get('ai_config')
            if not isinstance(config, dict):
                raise ValueError('AI configuration unavailable')
            config = {k: config.get(k) for k in ('stop_on_rare', 'stop_enemy_count', 'talent_weights')}
            validate_ai_config(config)
            raw = json.dumps(config, ensure_ascii=False, allow_nan=False, separators=(',', ':')).encode('utf-8')
            if len(raw) > 16384: raise ValueError('template too large')
            path.parent.mkdir(parents=True, exist_ok=True)
            path = self._template_path()
            temp = None
            try:
                with tempfile.NamedTemporaryFile(dir=path.parent, prefix='.ai-template-', delete=False) as f:
                    temp = f.name
                    f.write(raw); f.flush(); os.fsync(f.fileno())
                os.replace(temp, path)
            finally:
                if temp and os.path.exists(temp): os.unlink(temp)
            return self.observe()
        self.bridge.command({'type': 'pause'})
        with path.open('rb') as f: raw = f.read(16385)
        if len(raw) > 16384: raise ValueError('template too large')
        config = _strict_json(raw.decode('utf-8'))
        validate_ai_config(config)
        return self._snapshot(self.bridge.command({'type': 'ai_config', **config}))

    def _save(self):
        from .headless_bridge import MAX_LINE
        slot = self._slot_path()
        methods = self.bridge.worker_capabilities.get('methods', {})
        if self.bridge.boundary == 'decision' and isinstance(methods, dict) and methods.get('ai_stop') is True:
            self.bridge._receipt(self.bridge.request('act', {'type':'ai_stop'}, self.bridge.generation))
            if self.bridge.boundary != 'decision':
                self.bridge.close()
                raise RuntimeError('AI stop did not reach decision boundary; outcome unknown')
        result = self.bridge.request('save', {}, self.bridge.generation, self.bridge.startup_timeout)
        archive = result.get('archive') if isinstance(result, dict) else None
        if not isinstance(archive, dict) or archive.get('format') != 'tome-headless-snapshot-v1' or (type(archive.get('generation')) is not int or archive.get('generation') != self.bridge.generation):
            self.bridge.close()
            raise RuntimeError('invalid save receipt; outcome unknown')
        raw = json.dumps(archive, ensure_ascii=False, allow_nan=False, separators=(',', ':')).encode('utf-8')
        if len(raw) > 1048576 - 4096:
            raise ValueError('save exceeds restore protocol limit')
        slot.parent.mkdir(parents=True, exist_ok=True)
        slot = self._slot_path()
        temp_name = None
        try:
            with tempfile.NamedTemporaryFile(dir=slot.parent, prefix='.slot-', delete=False) as f:
                temp_name = f.name
                f.write(raw); f.flush(); os.fsync(f.fileno())
            os.replace(temp_name, slot)
        finally:
            if temp_name and os.path.exists(temp_name): os.unlink(temp_name)
        return self.observe()

    def _load(self):
        from .headless_bridge import HeadlessBridge, MAX_LINE, _strict_json
        slot = self._slot_path()
        with slot.open('rb') as f:
            raw = f.read(MAX_LINE + 1)
        if len(raw) > 1048576 - 4096:
            raise ValueError('save exceeds restore protocol limit')
        archive = _strict_json(raw.decode('utf-8'))
        if not isinstance(archive, dict) or archive.get('format') != 'tome-headless-snapshot-v1' or type(archive.get('generation')) is not int:
            raise ValueError('invalid save archive')
        old = self.bridge
        candidate = HeadlessBridge(old.argv, old.timeout, old.startup_timeout)
        try:
            candidate.start(empty=True)
            result = candidate.request('restore', {'archive': archive, 'min_generation': old.generation + 1}, timeout=candidate.startup_timeout)
            candidate._set_generation(result)
            if candidate.generation <= max(old.generation, archive['generation']) or result.get('boundary') not in ('decision', 'input'):
                raise RuntimeError('invalid restore generation or boundary')
            candidate._receipt(result)
            candidate.observe()
        except BaseException:
            candidate.close()
            self.record_failure(candidate)
            raise
        self.bridge = candidate
        old.close()
        return self.observe()

    def command(self, payload):
        if self.engineering_observe_only:
            raise ValueError("headless engineering scene is observe-only")
        if self.save_session is not None and payload.get('type') in ('ai_template_save', 'ai_template_load'):
            if set(payload) != {'type'} or self.observe().get('capabilities', {}).get(payload['type']) is not True:
                raise ValueError('unsupported template command')
            return self._template(payload['type'])
        if self.save_session is not None and payload.get('type') in ('save', 'load'):
            if set(payload) != {'type'}:
                raise ValueError('save and load do not accept paths or parameters')
            if self.observe().get('capabilities', {}).get(payload['type']) is not True:
                raise ValueError('unsupported command')
            return self._save() if payload['type'] == 'save' else self._load()
        if payload.get('type') == 'ai_config':
            validate_ai_config({k: v for k, v in payload.items() if k != 'type'})
        return self._snapshot(self.bridge.command(payload))

    def close(self):
        self.bridge.close()


def create_service(session="default", seed=7, backend="headless", config=None, fixture=None):
    if not re.fullmatch(r"[A-Za-z0-9_-]{1,64}", session):
        raise ValueError("invalid session name")
    if backend == "headless":
        if not config:
            raise ValueError("headless backend requires --config")
        from .headless_bridge import HeadlessBridge, load_config
        argv, timeout, startup_timeout = load_config(config)
        bridge = HeadlessBridge(argv, timeout, startup_timeout)
        try:
            bridge.start(seed=seed, fixture=fixture)
        except BaseException:
            bridge.close()
            raise
        return ServiceAdapter(bridge, save_session=session)
    if backend != "desktop":
        raise ValueError("unknown backend")
    try:
        module = importlib.import_module("tome_mvp.bridge")
    except ModuleNotFoundError as exc:
        if exc.name != "tome_mvp.bridge":
            raise
        return OfflineService()
    workspace = Path(__file__).resolve().parent.parent
    artifacts = workspace / "artifacts"
    root = artifacts / "tome-native-20261109"
    for path in (artifacts, root, root / session):
        if path.is_symlink():
            raise ValueError("session path must not be a symlink")
    if (root / session).exists() and any((root / session).iterdir()):
        raise ValueError("session directory must be empty")
    bridge = module.NativeBridge(root / session)
    try:
        bridge.start(seed=seed)
    except Exception:
        bridge.close()
        raise
    return ServiceAdapter(bridge)
