from pathlib import Path
from unittest.mock import patch
import tempfile
import unittest
from tome_mvp.bridge import NativeBridge
from tome_mvp.launch import prepare_host, ARTIFACT_ROOT


class NativeLaunchTests(unittest.TestCase):
    def test_generated_paths_and_direct_module(self):
        with tempfile.TemporaryDirectory(dir="artifacts/tome-native-20261109") as d:
            root = Path(d)
            install = root / "install"
            (install / "bootstrap").mkdir(parents=True)
            (install / "game" / "loader").mkdir(parents=True)
            (install / "bootstrap" / "boot.lua").write_text('print("Booting T-Engine from: "..x)', encoding="utf-8")
            (install / "game" / "loader" / "init.lua").write_text('load(...)', encoding="utf-8")
            occupied = root / "occupied"
            occupied.mkdir()
            (occupied / "file").write_text("retain")
            with self.assertRaises(ValueError):
                prepare_host(occupied, install)
            host = prepare_host(root / "session", install)
            boot = (host / "bootstrap" / "boot.lua").read_text(encoding="utf-8")
            self.assertIn('function fs.getUserPath()', boot)
            self.assertIn('isolated', boot)
            self.assertIn('"tome", "bridge", true', (host / "loader" / "init.lua").read_text(encoding="utf-8"))
            with self.assertRaises(ValueError):
                prepare_host(install, install)

    def test_unavailable_process_and_unsupported_seed(self):
        b = NativeBridge("artifacts/tome-native-20261109/no-scene")
        with self.assertRaises(ValueError):
            b.start(seed=-1)
        with self.assertRaises(RuntimeError):
            b.observe()
        with self.assertRaises(NotImplementedError):
            b.command({"type": "save"})

    def test_new_game_validates_and_forwards_seed(self):
        b = NativeBridge("artifacts/tome-native-20261109/no-scene")
        with patch.object(b, "_exchange", return_value={"generation": 2, "turn": 0}) as exchange:
            self.assertEqual(b.command({"type": "new_game", "seed": 8})["generation"], 2)
            exchange.assert_called_once_with("new_game", 8, timeout=b.startup_timeout)
            with self.assertRaises(ValueError):
                b.command({"type": "new_game", "seed": -1})
            self.assertEqual(exchange.call_count, 1)

    def test_danger_rejection_preserves_snapshot_and_process(self):
        class FakeProcess:
            def __init__(self):
                self.terminated = False

            def poll(self):
                return None

            def terminate(self):
                self.terminated = True

        with tempfile.TemporaryDirectory(dir="artifacts/tome-native-20261109") as d:
            root = Path(d)
            settings = root / "user" / "isolated" / "4.0" / "settings"
            settings.mkdir(parents=True)
            response = settings / "bridge-response.cfg"
            response.write_text('1|blocked_danger|{"status":"danger","turn":120}|END\n', encoding="utf-8")
            b = NativeBridge(root, timeout=1)
            process = FakeProcess()
            b.process = process
            with self.assertRaisesRegex(ValueError, "automatic action blocked by danger"):
                b.command({"type": "ai_step"})
            self.assertEqual(b.last_snapshot, {"status": "danger", "turn": 120})
            self.assertFalse(process.terminated)
            response.write_text('2|ok|{"status":"danger","turn":120}|END\n', encoding="utf-8")
            self.assertEqual(b.observe(), b.last_snapshot)
            self.assertFalse(process.terminated)


if __name__ == "__main__":
    unittest.main()
