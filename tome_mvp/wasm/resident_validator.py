"""Bounded process transport for a trusted, resident native validator.

This transport does not admit saves. SessionStore still owns version checks,
trusted baselines and commits. Failed or timed-out workers are discarded.
"""
from collections import deque
from contextlib import contextmanager
import json
from pathlib import Path
import queue
import subprocess
import threading
import time
import atexit

_pool_lock = threading.RLock()
_pool = {}
_reaper_stop = threading.Event()
_reaper_thread = None


def _reap_idle():
    with _pool_lock:
        for item in _pool.values():
            # Never wait on a running request or on a lease that spans COMMIT.
            if item.pool_pins or not item.lock.acquire(blocking=False):
                continue
            try:
                item.expire()
            finally:
                item.lock.release()


def _reaper_loop(stop, interval=10):
    while not stop.wait(interval):
        _reap_idle()


def _ensure_reaper():
    # Caller holds _pool_lock. Start once, only when a pool is actually used.
    global _reaper_thread
    if _reaper_thread is None or not _reaper_thread.is_alive():
        _reaper_thread = threading.Thread(target=_reaper_loop,
            args=(_reaper_stop,), daemon=True, name='tome-native-idle-reaper')
        _reaper_thread.start()


class ResidentValidator:
    def __init__(self, root, script, *, timeout=180, idle_seconds=120):
        self.root = Path(root).resolve()
        self.script = Path(script).resolve()
        self.timeout = timeout
        self.idle_seconds = idle_seconds
        self.lock = threading.RLock()
        self.transaction_lock = threading.RLock()
        self.partition_binding = None
        self.partition_cache = None
        self.partition_cache_pid = None
        self.pool_pins = 0
        self.process = None
        self.sequence = 0
        self.last_used = 0
        self.closed = False
        self.errors = deque(maxlen=20)
        self.responses = queue.Queue()

    def _start(self):
        if self.closed:
            raise RuntimeError('resident validator is closed')
        self.responses = queue.Queue()
        self.process = subprocess.Popen(
            ['node', str(self.script), str(self.root)],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, encoding='utf-8', bufsize=1,
            creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0))
        proc, responses = self.process, self.responses

        def read():
            try:
                for line in proc.stdout:
                    responses.put(line)
            finally:
                responses.put(None)

        def errors():
            for line in proc.stderr:
                self.errors.append(line[:1000])

        threading.Thread(target=read, daemon=True).start()
        threading.Thread(target=errors, daemon=True).start()

    def _stop(self):
        self.partition_binding = None
        self.partition_cache = None
        self.partition_cache_pid = None
        proc, self.process = self.process, None
        if proc is not None:
            if proc.poll() is None:
                proc.terminate()
                try:
                    proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.wait(timeout=5)
            for pipe in (proc.stdin, proc.stdout, proc.stderr):
                if pipe is not None:
                    pipe.close()

    def request(self, payload):
        # A caller may submit only its already-authorized validation request.
        with self.lock:
            now = time.monotonic()
            if self.process is not None and (
                    self.process.poll() is not None or now - self.last_used > self.idle_seconds):
                self._stop()
            if self.process is None:
                self._start()
            self.sequence += 1
            sequence = self.sequence
            try:
                request = json.dumps({'id': sequence, 'request': payload}, ensure_ascii=False,
                                     separators=(',', ':'), allow_nan=False)
                self.process.stdin.write(request + '\n')
                self.process.stdin.flush()
                line = self.responses.get(timeout=self.timeout)
                if line is None:
                    raise RuntimeError('resident native validator exited')
                result = json.loads(line)
                if result.get('id') != sequence or not isinstance(result.get('result'), dict):
                    raise RuntimeError('invalid resident validator response')
                self.last_used = time.monotonic()
                response=result['result']
                if response.get('ok') is not True:
                    self._stop()
                return response
            except Exception:
                self._stop()
                raise

    def abort_pending(self,token):
        """Abort only a live process; never start a replacement to abort it."""
        with self.lock:
            try:
                if self.process is not None and self.process.poll() is None:
                    self.request({'kind':'abort','pending_token':token})
            except BaseException:
                pass
            finally:
                self._stop()

    def discard(self):
        """Destroy the current VM after an uncertain or rejected candidate."""
        with self.lock:
            self._stop()

    def close(self):
        with self.lock:
            self.closed = True
            self._stop()

    def expire(self):
        with self.lock:
            if self.process is not None and time.monotonic() - self.last_used > self.idle_seconds:
                self._stop()


class ResidentCapacityError(RuntimeError):
    pass


def validator_for(path, root, script):
    """Reuse at most four local runtimes; source changes invalidate the key."""
    root, script = Path(root).resolve(), Path(script).resolve()
    identity = root.parent / 'identity.json'
    key = (str(Path(path).resolve()), str(root), str(script), identity.stat().st_mtime_ns,
           script.stat().st_mtime_ns)
    with _pool_lock:
        _ensure_reaper()
        for item in _pool.values():
            if item.pool_pins==0:item.expire()
        if key not in _pool:
            while len(_pool) >= 4:
                available=[k for k,v in _pool.items() if v.pool_pins==0]
                if not available:raise ResidentCapacityError('all resident validators leased')
                oldest = min(available, key=lambda k: _pool[k].last_used)
                _pool.pop(oldest).close()
            _pool[key] = ResidentValidator(root, script)
        return _pool[key]


@contextmanager
def partition_validator_lease(path,root,script):
    """Pin from pool lookup through COMMIT/confirm; an active lease cannot be evicted."""
    with _pool_lock:
        validator=validator_for(path,root,script)
        validator.pool_pins+=1
    try:
        with validator.transaction_lock:
            yield validator
    finally:
        with _pool_lock:
            validator.pool_pins-=1


def close_all():
    with _pool_lock:
        for item in _pool.values():
            item.close()
        _pool.clear()


def _shutdown():
    _reaper_stop.set()
    close_all()


atexit.register(_shutdown)
