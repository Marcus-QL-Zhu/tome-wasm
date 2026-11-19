"""Owned worker processes for the native bridge."""
import ctypes
import os
import subprocess
import queue
import signal
import sys
import threading
from ctypes import wintypes


if os.name == "nt":
    class BasicLimits(ctypes.Structure):
        _fields_ = [("PerProcessUserTimeLimit", ctypes.c_int64), ("PerJobUserTimeLimit", ctypes.c_int64),
                    ("LimitFlags", wintypes.DWORD), ("MinimumWorkingSetSize", ctypes.c_size_t),
                    ("MaximumWorkingSetSize", ctypes.c_size_t), ("ActiveProcessLimit", wintypes.DWORD),
                    ("Affinity", ctypes.c_size_t), ("PriorityClass", wintypes.DWORD),
                    ("SchedulingClass", wintypes.DWORD)]

    class IoCounters(ctypes.Structure):
        _fields_ = [(name, ctypes.c_uint64) for name in (
            "ReadOperationCount", "WriteOperationCount", "OtherOperationCount",
            "ReadTransferCount", "WriteTransferCount", "OtherTransferCount")]

    class ExtendedLimits(ctypes.Structure):
        _fields_ = [("BasicLimitInformation", BasicLimits), ("IoInfo", IoCounters),
                    ("ProcessMemoryLimit", ctypes.c_size_t), ("JobMemoryLimit", ctypes.c_size_t),
                    ("PeakProcessMemoryUsed", ctypes.c_size_t), ("PeakJobMemoryUsed", ctypes.c_size_t)]

    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel.CreateJobObjectW.argtypes = [ctypes.c_void_p, wintypes.LPCWSTR]
    kernel.CreateJobObjectW.restype = wintypes.HANDLE
    kernel.SetInformationJobObject.argtypes = [wintypes.HANDLE, ctypes.c_int, ctypes.c_void_p, wintypes.DWORD]
    kernel.SetInformationJobObject.restype = wintypes.BOOL
    kernel.AssignProcessToJobObject.argtypes = [wintypes.HANDLE, wintypes.HANDLE]
    kernel.AssignProcessToJobObject.restype = wintypes.BOOL
    kernel.CloseHandle.argtypes = [wintypes.HANDLE]
    kernel.CloseHandle.restype = wintypes.BOOL
    ntdll = ctypes.WinDLL("ntdll")
    ntdll.NtResumeProcess.argtypes = [wintypes.HANDLE]
    ntdll.NtResumeProcess.restype = ctypes.c_long


class OwnedJob:
    def __init__(self):
        self.handle = None
        if os.name != "nt":
            raise OSError("Windows Job Object is required for native host ownership")
        self.handle = kernel.CreateJobObjectW(None, None)
        if not self.handle:
            raise ctypes.WinError(ctypes.get_last_error())
        limits = ExtendedLimits()
        limits.BasicLimitInformation.LimitFlags = 0x00002000  # KILL_ON_JOB_CLOSE
        if not kernel.SetInformationJobObject(self.handle, 9, ctypes.byref(limits), ctypes.sizeof(limits)):
            error = ctypes.WinError(ctypes.get_last_error())
            self.close()
            raise error

    def assign(self, process):
        if not kernel.AssignProcessToJobObject(self.handle, int(process._handle)):
            raise ctypes.WinError(ctypes.get_last_error())

    def close(self):
        if self.handle:
            kernel.CloseHandle(self.handle)
            self.handle = None

    def __del__(self):
        self.close()


class PosixOwnedJob:
    """Own one dedicated worker session, never an arbitrary process group."""
    def __init__(self, process):
        self.process = process

    def close(self):
        process, self.process = self.process, None
        if process is None:
            return
        # Prevent Popen's waiter from reaping and freeing the leader PID until
        # killpg completes. WNOWAIT inspects exit without consuming its status.
        with process._waitpid_lock:
            if process.returncode is not None:
                return
            try:
                status = os.waitid(os.P_PID, process.pid, os.WEXITED | os.WNOHANG | os.WNOWAIT)
                if status is None:
                    os.killpg(process.pid, signal.SIGKILL)
            except (ProcessLookupError, ChildProcessError):
                pass



def _popen_owned_linux(args, **kwargs):
    if kwargs.get("preexec_fn") is not None:
        raise ValueError("preexec_fn is unsafe in the threaded service")
    if kwargs.get("start_new_session", True) is not True:
        raise ValueError("owned worker needs its own session")
    kwargs["start_new_session"] = True
    env = dict(os.environ if kwargs.get("env") is None else kwargs["env"])
    env["TOME_OWNER_PID"] = str(os.getpid())
    kwargs["env"] = env
    result = queue.Queue(maxsize=1)

    def launch_and_reap():
        # Linux parent-death signals follow the creating thread, not merely the
        # process. Keep this daemon thread alive until its worker has exited.
        try:
            process = subprocess.Popen(args, **kwargs)
        except BaseException as error:
            result.put((None, error))
            return
        process._tome_owned_job = PosixOwnedJob(process)
        result.put((process, None))
        while True:
            try:
                process.wait(timeout=0.2)
                break
            except subprocess.TimeoutExpired:
                pass

    threading.Thread(target=launch_and_reap, name="tome-worker-owner", daemon=True).start()
    process, error = result.get()
    if error is not None:
        raise error
    return process


def popen_owned(args, **kwargs):
    """Start a child and retain its non-inheritable kill-on-close job handle."""
    if sys.platform.startswith("linux"):
        return _popen_owned_linux(args, **kwargs)
    job = OwnedJob()
    process = None
    try:
        # Bind before the child executes; ordinary Popen does not expose its
        # primary thread handle, so resume the suspended process as a whole.
        kwargs["creationflags"] = kwargs.get("creationflags", 0) | 0x00000004
        process = subprocess.Popen(args, **kwargs)
        job.assign(process)
        status = ntdll.NtResumeProcess(int(process._handle))
        if status != 0:
            raise OSError(f"NtResumeProcess failed: {status:#x}")
        process._tome_owned_job = job
        return process
    except BaseException:
        if process is not None and process.poll() is None:
            process.kill()
            process.wait(timeout=5)
        job.close()
        raise


def close_owned_job(process):
    job = getattr(process, "_tome_owned_job", None)
    if job is not None:
        job.close()
        process._tome_owned_job = None
