"""Bounded native Lua rescue probes; requires the local Windows worker build."""
import json
import os
from pathlib import Path
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]
BUILD = Path(os.environ.get('TOME_HEADLESS_BUILD_DIR', ROOT / 'artifacts/tome-rescue-20261111/candidate'))


class NativeRescueTest(unittest.TestCase):
    def probe(self, name, marker):
        config = BUILD / 'worker_config.json'
        if not config.is_file():
            self.skipTest('native candidate build unavailable')
        argv = json.loads(config.read_text(encoding='utf-8'))['worker_argv']
        argv[1] = str(BUILD / (name + '.read.log'))
        argv[2] = '/' + name
        result = subprocess.run(argv, capture_output=True, text=True, encoding='utf-8', errors='replace', timeout=90)
        self.assertEqual(result.returncode, 0, result.stderr[-3000:])
        self.assertIn(marker, result.stdout)

    def test_native_basics(self):
        self.probe('rescue_probe.lua', 'PASS_RESCUE_BASIC')

    def test_native_scheduler(self):
        self.probe('rescue_scheduler_probe.lua', 'PASS_RESCUE_SCHEDULER_20')

    def test_native_invariants_and_persistence(self):
        self.probe('rescue_invariants_probe.lua', 'PASS_RESCUE_INVARIANTS')

    def test_native_area_damage(self):
        self.probe('rescue_aoe_probe.lua', 'PASS_RESCUE_AOE_ALL_THREE')

    def test_native_interruptions(self):
        self.probe('rescue_interrupt_probe.lua', 'PASS_RESCUE_INTERRUPTS')


if __name__ == '__main__':
    unittest.main()
