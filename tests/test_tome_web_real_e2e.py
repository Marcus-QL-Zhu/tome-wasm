"""Optional real-worker + HTTP + shipped app.js regression.

Set TOME_E2E_WORKER_CONFIG to a verified candidate JSON config. Optionally set
TOME_E2E_PORT to a free loopback port (default 0). Node 18+ is required.
Results are written to artifacts/tome-web-real-e2e/.
"""
import os
from pathlib import Path
import shutil
import subprocess
import threading
import unittest

from tome_mvp.headless_bridge import HeadlessBridge, load_config
from tome_mvp.server import create_server
from tome_mvp.service import ServiceAdapter

ROOT = Path(__file__).resolve().parents[1]
RESULTS = Path(os.environ.get("TOME_E2E_RESULTS_DIR", str(ROOT / "artifacts" / "tome-web-real-e2e")))


class WebRealE2ETests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.node = shutil.which("node")
        config = os.environ.get("TOME_E2E_WORKER_CONFIG")
        if not cls.node:
            raise unittest.SkipTest("Node 18+ is required")
        if not config or not Path(config).is_file():
            raise unittest.SkipTest("set TOME_E2E_WORKER_CONFIG to an existing candidate config")
        check = subprocess.run([cls.node, "-e", "if(typeof fetch !== 'function')process.exit(1)"], capture_output=True)
        if check.returncode:
            raise unittest.SkipTest("Node with built-in fetch is required")
        cls.argv, cls.timeout, cls.startup = load_config(config)
        if not Path(cls.argv[0]).is_file():
            raise unittest.SkipTest("configured native worker executable is missing")
        cls.port = int(os.environ.get("TOME_E2E_PORT", "0"))
        if not 0 <= cls.port <= 65535:
            raise ValueError("TOME_E2E_PORT must be a valid port")
        RESULTS.mkdir(parents=True, exist_ok=True)

    def run_scenario(self, name, fixture=None):
        bridge = HeadlessBridge(self.argv, self.timeout, self.startup)
        service = None
        server = None
        thread = None
        try:
            bridge.start(seed=11, fixture=fixture)
            service = ServiceAdapter(bridge)
            server = create_server(service, self.port)
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            result = subprocess.run([self.node, str(ROOT / "tests" / "tome_web_real_e2e.js"),
                                     f"http://127.0.0.1:{server.server_port}", name],
                                    cwd=ROOT, capture_output=True, text=True, encoding="utf-8", timeout=180)
            (RESULTS / f"{name}.json").write_text(result.stdout, encoding="utf-8")
            (RESULTS / f"{name}.stderr.log").write_text(result.stderr, encoding="utf-8")
            self.assertEqual(result.returncode, 0, result.stderr)
        finally:
            if server is not None:
                server.shutdown()
                server.server_close()
            if service is not None:
                service.close()
            else:
                bridge.close()
            if thread is not None:
                thread.join()

    def test_stop_human_restart_and_budget(self):
        self.run_scenario("stop_restart")

    def test_rescue_takeover_and_return(self):
        if os.environ.get("TOME_E2E_RESCUE") != "1":
            self.skipTest("set TOME_E2E_RESCUE=1 for a rescue-enabled isolated candidate")
        self.run_scenario("rescue", fixture="rescue")

    def test_rescue_pause_revokes_epoch_and_cancel(self):
        if os.environ.get("TOME_E2E_RESCUE") != "1":
            self.skipTest("set TOME_E2E_RESCUE=1 for a rescue-enabled isolated candidate")
        self.run_scenario("rescue_pause", fixture="rescue")

    def test_two_party_down_events_require_confirmation(self):
        if os.environ.get("TOME_E2E_RESCUE") != "1":
            self.skipTest("set TOME_E2E_RESCUE=1 for a rescue-enabled isolated candidate")
        self.run_scenario("down_events")

    def test_unconfirmed_down_fixed_slot_restore(self):
        if os.environ.get("TOME_E2E_RESCUE") != "1":
            self.skipTest("set TOME_E2E_RESCUE=1 for a rescue-enabled isolated candidate")
        import tempfile
        from unittest.mock import patch
        bridge = HeadlessBridge(self.argv, self.timeout, self.startup)
        service = ServiceAdapter(bridge, save_session="rescue-ack-test")
        try:
            initial = bridge.start(seed=11, fixture="rescue")
            event = initial["down_events"][0]
            self.assertEqual(initial["status"], "awaiting_down_confirmation")
            self.assertTrue(initial["capabilities"]["save"])
            with tempfile.TemporaryDirectory(dir=ROOT / "artifacts") as directory:
                with patch.object(service, "_slot_path", return_value=Path(directory) / "slot.json"):
                    service.command({"type":"save"})
                    confirmed = service.command({"type":"confirm_down", "event_id":event["id"], "generation":initial["generation"]})
                    self.assertEqual(confirmed["turn"], initial["turn"])
                    restored = service.command({"type":"load"})
                    self.assertEqual(restored["status"], "awaiting_down_confirmation")
                    self.assertEqual(restored["down_events"], initial["down_events"])
                    self.assertEqual(restored["turn"], initial["turn"])
                    self.assertGreater(restored["generation"], initial["generation"])
                    with self.assertRaises(ValueError):
                        service.command({"type":"confirm_down", "event_id":event["id"], "generation":initial["generation"]})
                    self.assertEqual(service.observe()["down_events"], initial["down_events"])
        finally:
            service.close()

    def test_rescue_control_save_restore(self):
        if os.environ.get("TOME_E2E_RESCUE") != "1":
            self.skipTest("set TOME_E2E_RESCUE=1 for a rescue-enabled isolated candidate")
        from tome_mvp.headless_bridge import WorkerRejected
        old = HeadlessBridge(self.argv, self.timeout, self.startup)
        new = HeadlessBridge(self.argv, self.timeout, self.startup)
        try:
            initial = old.start(seed=11, fixture="rescue")
            old.command({"type":"confirm_down", "event_id":initial["down_events"][0]["id"], "generation":initial["generation"]})
            selected = old.command({"type":"takeover", "target":initial["party"][1]["id"]})
            archive = old.request("save", {}, old.generation)["archive"]
            new.start(empty=True)
            result = new.request("restore", {"archive":archive,"min_generation":old.generation+1}, timeout=new.startup_timeout)
            new._set_generation(result)
            restored = new.observe()
            self.assertEqual(restored["control_actor_id"], selected["control_actor_id"])
            self.assertEqual(restored["leader_id"], selected["leader_id"])
            self.assertTrue(restored["party"][0]["down"])
            active = new.command({"type":"rescue_start", "target":restored["leader_id"]})
            self.assertFalse(active["capabilities"]["save"])
            with self.assertRaises(WorkerRejected):
                new.request("save", {}, new.generation)
        finally:
            old.close()
            new.close()

    def test_lost_action_response_attempts_pause(self):
        self.run_scenario("response_loss")

    def test_rest_naturally_transitions_to_explore(self):
        self.run_scenario("recovery_transition", fixture="recovery")


if __name__ == "__main__":
    unittest.main()
