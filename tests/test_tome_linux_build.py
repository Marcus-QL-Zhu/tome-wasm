import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('linux_build', ROOT / 'scripts/build_tome_headless_linux.py')
build = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(build)


class LinuxBuildTest(unittest.TestCase):
    def run_build(self, output, run):
        with patch.object(sys, 'argv', ['build', '--output', str(output)]), \
             patch.object(sys, 'platform', 'linux'), \
             patch.object(build.shutil, 'which', return_value='/usr/bin/gcc'), \
             patch.object(build.subprocess, 'run', side_effect=run):
            build.main()

    def test_generation_plan_and_absolute_config(self):
        actual_run = subprocess.run
        commands = []
        def run(command, **kwargs):
            commands.append(command)
            if command[0] == '/usr/bin/gcc':
                if '--version' in command:
                    return subprocess.CompletedProcess(command, 0, stdout='gcc test\n')
                Path(command[command.index('-o') + 1]).write_bytes(b'fake')
                return subprocess.CompletedProcess(command, 0)
            return actual_run(command, **kwargs)
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / 'out'
            self.run_build(out, run)
            config = json.loads((out / 'worker_config.json').read_text())
            self.assertEqual(config['worker_argv'][0], str(out / 'worker_host'))
            self.assertEqual(config['worker_argv'][2], '/worker.lua')
            self.assertTrue(all(Path(p).is_absolute() for p in [config['worker_argv'][0], *config['worker_argv'][3:]]))
            compiler = next(c for c in commands if c[0] == '/usr/bin/gcc' and '-o' in c)
            self.assertIn('-lm', compiler)
            self.assertIn('-ldl', compiler)
            self.assertIn(str(build.ROOT / 'tome_mvp/headless/worker_host.c'), compiler)
            self.assertTrue((out / 'pure_fov.c').is_file())
            self.assertTrue((out / 'directories.lua').is_file())
            self.assertIn('return dup2(oldfd, newfd) < 0 ? -1 : 0;', (out / 'io.h').read_text())
            self.assertEqual(json.loads((out / 'build_provenance.json').read_text())['source_core_sha256'], build.CORE_HASH)

    def test_rejects_missing_inputs_and_removes_stale_config(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / 'out'
            out.mkdir()
            (out / 'worker_config.json').write_text('stale')
            with patch.object(build, 'ROOT', Path(tmp) / 'missing'):
                with self.assertRaises(FileNotFoundError):
                    self.run_build(out, lambda *a, **k: None)
            self.assertFalse((out / 'worker_config.json').exists())

    def test_rejects_changed_core_hash(self):
        with tempfile.TemporaryDirectory() as tmp:
            with patch.object(build, 'CORE_HASH', 'bad'):
                with self.assertRaisesRegex(SystemExit, 'core_lua.c hash'):
                    self.run_build(Path(tmp) / 'out', lambda *a, **k: None)
            self.assertFalse((Path(tmp) / 'out/worker_config.json').exists())


if __name__ == '__main__':
    unittest.main()
