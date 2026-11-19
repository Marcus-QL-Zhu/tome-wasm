import ctypes
import os
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path


@unittest.skipUnless(os.name == "nt", "Windows Job Object test")
class OwnedJobTests(unittest.TestCase):
    def test_killed_owner_cleans_only_its_child(self):
        from ctypes import wintypes
        kernel = ctypes.WinDLL("kernel32", use_last_error=True)
        kernel.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
        kernel.OpenProcess.restype = wintypes.HANDLE
        kernel.WaitForSingleObject.argtypes = [wintypes.HANDLE, wintypes.DWORD]
        kernel.WaitForSingleObject.restype = wintypes.DWORD
        kernel.TerminateProcess.argtypes = [wintypes.HANDLE, wintypes.UINT]
        kernel.CloseHandle.argtypes = [wintypes.HANDLE]
        code = '''
import pathlib, subprocess, sys, time
from tome_mvp.native.job import popen_owned
child = popen_owned([sys.executable, "-c", "import time; time.sleep(60)"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
pathlib.Path(sys.argv[1]).write_text(str(child.pid), encoding="ascii")
time.sleep(60)
'''
        with tempfile.TemporaryDirectory(dir="artifacts/tome-native-20261109") as d:
            marker = Path(d) / "child.pid"
            owner = subprocess.Popen([sys.executable, "-c", code, str(marker)], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
            child_handle = None
            try:
                deadline = time.monotonic() + 12
                while not marker.exists() and owner.poll() is None and time.monotonic() < deadline:
                    time.sleep(.05)
                if not marker.exists():
                    if owner.poll() is None:
                        self.fail("test owner did not publish its child within 12 seconds")
                    self.fail("job setup failed: " + owner.stderr.read().decode(errors="replace"))
                child_pid = int(marker.read_text(encoding="ascii"))
                child_handle = kernel.OpenProcess(0x00100001, False, child_pid)  # SYNCHRONIZE | TERMINATE
                self.assertTrue(child_handle, "could not open the test child")
                self.assertEqual(kernel.WaitForSingleObject(child_handle, 0), 258, "test child was not running")
                owner.kill()
                owner.wait(timeout=5)
                self.assertEqual(kernel.WaitForSingleObject(child_handle, 8000), 0, "child survived owner death")
            finally:
                if owner.poll() is None:
                    owner.kill()
                    owner.wait(timeout=5)
                if child_handle:
                    if kernel.WaitForSingleObject(child_handle, 0) == 258:
                        kernel.TerminateProcess(child_handle, 1)  # only the test child handle
                        kernel.WaitForSingleObject(child_handle, 5000)
                    kernel.CloseHandle(child_handle)
                owner.stderr.close()
