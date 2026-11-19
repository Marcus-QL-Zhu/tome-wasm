import os
from pathlib import Path
import subprocess
import threading
import unittest
from unittest.mock import patch
from contextlib import ExitStack
from tome_mvp.native import job

class FakeProcess:
    def __init__(self):
        self.pid = 43210
        self.done = threading.Event()
        self.wait_entered = threading.Event()
        self.running = True
        self.returncode = None
        self._waitpid_lock = threading.Lock()
    def poll(self): return None if self.running else 0
    def wait(self, timeout=None):
        self.wait_entered.set()
        if not self.done.wait(timeout): raise subprocess.TimeoutExpired('worker', timeout)
        return 0

def posix_mocks(stack, status=None):
    kill = stack.enter_context(patch.object(job.os, 'killpg', create=True))
    stack.enter_context(patch.object(job.signal, 'SIGKILL', 9, create=True))
    stack.enter_context(patch.object(job.os, 'waitid', return_value=status, create=True))
    for name, value in [('P_PID', 1), ('WEXITED', 2), ('WNOHANG', 4), ('WNOWAIT', 8)]:
        stack.enter_context(patch.object(job.os, name, value, create=True))
    return kill

class LinuxOwnershipTest(unittest.TestCase):
    def test_launch_retains_owner_and_closes_only_own_group(self):
        child = FakeProcess()
        try:
            with ExitStack() as stack:
                launch = stack.enter_context(patch.object(job.subprocess, 'Popen', return_value=child))
                kill = posix_mocks(stack)
                results = []
                request_thread = threading.Thread(target=lambda: results.append(job._popen_owned_linux(['/worker'], stdin=subprocess.PIPE)))
                request_thread.start(); request_thread.join(2)
                self.assertFalse(request_thread.is_alive())
                self.assertTrue(child.wait_entered.wait(1))
                self.assertFalse(child.done.is_set())
                self.assertIs(results[0], child)
                options = launch.call_args.kwargs
                self.assertTrue(options['start_new_session'])
                self.assertEqual(str(os.getpid()), options['env']['TOME_OWNER_PID'])
                self.assertNotIn('preexec_fn', options)
                job.close_owned_job(child)
                kill.assert_called_once_with(child.pid, 9)
                job.close_owned_job(child)
                self.assertEqual(kill.call_count, 1)
        finally: child.done.set()

    def test_dead_child_is_not_signalled_and_launch_errors_propagate(self):
        child = FakeProcess(); child.returncode = 0
        with ExitStack() as stack:
            kill = posix_mocks(stack)
            job.PosixOwnedJob(child).close()
            kill.assert_not_called()
        with ExitStack() as stack:
            kill = posix_mocks(stack, status=object())
            child.returncode = None
            job.PosixOwnedJob(child).close()
            kill.assert_not_called()
        with patch.object(job.subprocess, 'Popen', side_effect=OSError('missing')):
            with self.assertRaisesRegex(OSError, 'missing'):
                job._popen_owned_linux(['/missing'])

    def test_unsafe_options_rejected(self):
        with self.assertRaises(ValueError): job._popen_owned_linux(['x'], preexec_fn=lambda: None)
        with self.assertRaises(ValueError): job._popen_owned_linux(['x'], start_new_session=False)

    def test_linux_host_constructor_fail_closed(self):
        header = (Path(__file__).resolve().parents[1]/'tome_mvp/headless/posix_io_compat.h').read_text(encoding='utf-8-sig')
        self.assertIn('PR_SET_PDEATHSIG, SIGKILL', header)
        self.assertIn('getppid() != (pid_t)expected', header)
        self.assertIn('TOME_OWNER_PID', header)
        self.assertIn('__attribute__((constructor))', header)

if __name__ == '__main__': unittest.main()
