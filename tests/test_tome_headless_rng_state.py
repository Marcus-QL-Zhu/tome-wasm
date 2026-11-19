"""Exercise actual C SFMT and normal spare across independent hosts."""
import os
from pathlib import Path
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]
BUILD = Path(os.environ.get('TOME_HEADLESS_BUILD_DIR', ROOT / 'artifacts/tome-native-expansion-20261109/candidate'))


class RngStateTest(unittest.TestCase):
    def run_probe(self, script, payload=None):
        exe = BUILD / 'worker_host.exe'
        if not exe.is_file():
            self.skipTest('candidate build is unavailable')
        cmd = [str(exe), str(BUILD / 'rng-state-read.log'), '/' + script,
               str(ROOT / 'tome_mvp/headless')]
        result = subprocess.run(cmd, input=payload, capture_output=True, text=True,
                                encoding='utf-8', timeout=20)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout

    def test_graph_cycles_aliases_and_rejection(self):
        self.assertIn('PASS_GRAPH_CYCLES_ALIASES_AND_REJECTION', self.run_probe('graph_codec_test.lua'))

    def test_same_process_and_invalid_state(self):
        self.assertIn('PASS_SFMT_NORMAL_RESTORE_AND_REJECT', self.run_probe('rng_state_test.lua'))

    def test_cross_process_and_roundtrip_precision(self):
        snapshot = self.run_probe('rng_state_export_test.lua')
        self.assertIn('PASS_CROSS_PROCESS_SFMT_NORMAL', self.run_probe('rng_state_import_test.lua', snapshot))


if __name__ == '__main__':
    unittest.main()
