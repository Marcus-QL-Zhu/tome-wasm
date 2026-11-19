from __future__ import annotations

import http.client
import json
import threading
import unittest
from tome_mvp.server import create_server


class FakeService:
    def __init__(self): self.calls = []; self.ai_status = "idle"
    def observe(self): return {"map": [" " * 64] * 64, "turn": len(self.calls), "ai_status": self.ai_status, "capabilities": {"wait": True, "melee": True, "ranged": "true", "ai_step": True, "ai_start": True, "pause": True, "new_game": True}}
    def command(self, payload):
        self.calls.append(payload)
        if payload["type"] == "ai_start": self.ai_status = "running"
        if payload["type"] in ("pause", "new_game", "load"): self.ai_status = "stopped"
        return self.observe()
    def close(self): pass


class ServerTests(unittest.TestCase):
    def setUp(self):
        self.service = FakeService()
        self.server = create_server(self.service)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.host = f"127.0.0.1:{self.server.server_port}"

    def tearDown(self):
        self.server.shutdown(); self.server.server_close(); self.thread.join()

    def request(self, method, path, body=None, headers=None):
        c = http.client.HTTPConnection("127.0.0.1", self.server.server_port, timeout=3)
        c.request(method, path, body, headers or {})
        r = c.getresponse(); data = r.read(); status = r.status; c.close()
        return status, data

    def post(self, data, **headers):
        h = {"Origin": "http://" + self.host, "Content-Type": "application/json"}; h.update(headers)
        return self.request("POST", "/api/command", json.dumps(data), h)

    def test_rescue_step_requires_current_control_epoch(self):
        original = self.service.observe
        def observe():
            state = original()
            state["capabilities"].update(rescue_start=True, rescue_step=True, rescue_cancel=True)
            return state
        self.service.observe = observe
        status, body = self.post({"type":"rescue_start", "target":"1", "revision":0})
        self.assertEqual(status, 200)
        epoch = json.loads(body)["control_epoch"]
        self.assertEqual(self.post({"type":"rescue_step", "revision":1})[0], 409)
        status, body = self.post({"type":"rescue_step", "revision":1, "control_epoch":epoch})
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body)["control_epoch"], epoch)
        status, body = self.post({"type":"pause", "revision":2})
        self.assertEqual(status, 200)
        self.assertNotEqual(json.loads(body)["control_epoch"], epoch)
        self.assertEqual(self.post({"type":"rescue_step", "revision":3, "control_epoch":epoch})[0], 409)
        self.assertEqual([call["type"] for call in self.service.calls], ["rescue_start", "rescue_step", "pause"])

    def test_state_commands_and_stale_revision(self):
        status, data = self.request("GET", "/api/state")
        self.assertEqual((status, json.loads(data)["revision"]), (200, 0))
        status, data = self.post({"type": "wait", "revision": 0})
        self.assertEqual((status, json.loads(data)["revision"]), (200, 1))
        self.assertEqual(self.post({"type": "wait", "revision": 0})[0], 409)
        self.assertEqual(self.service.calls, [{"type": "wait"}])

    def test_origin_type_body_and_paths(self):
        self.assertEqual(self.post({"revision": 0}, Origin="http://evil.example")[0], 403)
        self.assertEqual(self.post({"revision": 0}, **{"Content-Type": "text/plain"})[0], 415)
        self.assertEqual(self.post({"revision": True})[0], 400)
        self.assertEqual(self.request("GET", "/../server.py")[0], 404)
        self.assertEqual(self.request("GET", "/api/state?x=1")[0], 404)
        self.assertEqual(self.request("GET", "/")[0], 200)
        self.assertEqual(self.request("POST", "/api/command", "x" * 16385, {"Origin": "http://" + self.host, "Content-Type": "application/json"})[0], 400)
        self.assertFalse(self.service.calls)

    def test_reject_ambiguous_json_transfer_encoding_and_host(self):
        headers = {"Origin": "http://" + self.host, "Content-Type": "application/json"}
        for raw in ('{"revision":0,"revision":0}', '{"revision":0,"x":NaN}', '{"revision":0,"x":Infinity}', '{"revision":0,"nested":{"x":1,"x":2}}'):
            self.assertEqual(self.request("POST", "/api/command", raw, headers)[0], 400)
        self.assertEqual(self.request("POST", "/api/command", '{"revision":0}', {**headers, "Transfer-Encoding": "chunked"})[0], 400)
        self.assertEqual(self.request("GET", "/api/state", headers={"Host": "attacker.example"})[0], 403)
        self.assertFalse(self.service.calls)

    def test_capabilities_are_strict_and_modes_separate(self):
        self.assertEqual(self.post({"revision": 0, "type": "attack", "mode": "ranged"})[0], 403)
        self.assertEqual(self.post({"revision": 0, "type": "attack", "mode": "melee"})[0], 200)
        self.assertEqual(len(self.service.calls), 1)

    def test_slow_reply_does_not_hold_lock(self):
        entered, release = threading.Event(), threading.Event()
        handler = self.server.RequestHandlerClass
        original = handler.reply
        def delayed(instance, status, body, *args):
            if instance.command == "POST":
                entered.set()
                release.wait(2)
            return original(instance, status, body, *args)
        handler.reply = delayed
        worker = threading.Thread(target=lambda: self.post({"revision": 0, "type": "wait"}))
        worker.start()
        try:
            self.assertTrue(entered.wait(1))
            status, body = self.request("GET", "/api/state")
            self.assertEqual((status, json.loads(body)["revision"]), (200, 1))
        finally:
            release.set(); worker.join()

    def test_cross_client_pause_invalidates_frozen_ai_epoch(self):
        self.assertEqual(self.post({"revision": 0, "type": "ai_start", "budget": 10})[0], 200)
        entered, release = threading.Event(), threading.Event()
        original = self.service.command
        def delayed(payload):
            if payload.get("type") == "ai_step":
                entered.set()
                if not release.wait(2): raise RuntimeError("timeout")
            return original(payload)
        self.service.command = delayed
        results = {}
        ai = threading.Thread(target=lambda: results.update(ai=self.post({"revision": 1, "control_epoch": 1, "type": "ai_step"})))
        pause = threading.Thread(target=lambda: results.update(pause=self.post({"revision": 1, "type": "pause"})))
        ai.start()
        try:
            self.assertTrue(entered.wait(1))
            pause.start()
        finally:
            release.set()
            ai.join(); pause.join()
        self.assertEqual(results["ai"][0], 200)
        self.assertEqual(results["pause"][0], 200)
        state = json.loads(results["pause"][1])
        self.assertEqual((state["revision"], state["control_epoch"]), (3, 2))
        self.assertEqual(self.post({"revision": 3, "control_epoch": 1, "type": "ai_step"})[0], 409)
        self.assertEqual(self.post({"revision": 3, "control_epoch": 2, "type": "ai_step"})[0], 409)
        self.assertEqual([item["type"] for item in self.service.calls], ["ai_start", "ai_step", "pause"])
        self.assertEqual(self.post({"revision": 3, "type": "ai_start", "budget": 10})[0], 200)
        self.assertEqual(self.post({"revision": 4, "control_epoch": 3, "type": "ai_step"})[0], 200)

    def test_missing_load_slot_revokes_existing_ai_authorization(self):
        _, body = self.post({"revision": 0, "type": "ai_start", "budget": 10})
        state = json.loads(body)
        old = state["control_epoch"]
        status, body = self.post({"revision": state["revision"], "type": "load"})
        self.assertEqual(status, 403)
        state = json.loads(body)
        self.assertEqual(self.service.ai_status, "stopped")
        self.assertEqual(self.post({"revision": state["revision"], "control_epoch": old, "type": "ai_step"})[0], 409)

    def test_budget_is_integral_and_exhaustion_stops_without_client_pause(self):
        for budget in (1.5, 0, 501, True, "1"):
            self.assertEqual(self.post({"type": "ai_start", "revision": 0, "budget": budget})[0], 400)
        status, body = self.post({"type": "ai_start", "revision": 0, "budget": 1})
        self.assertEqual(status, 200)
        start = json.loads(body)
        status, body = self.post({"type": "ai_step", "revision": 1, "control_epoch": start["control_epoch"]})
        state = json.loads(body)
        self.assertEqual((status, state["ai_status"], state["ai_remaining"], state["ai_control_reason"]), (200, "stopped", 0, "budget_exhausted"))
        self.assertEqual(self.post({"type": "ai_step", "revision": state["revision"], "control_epoch": start["control_epoch"]})[0], 409)
        self.assertEqual([c["type"] for c in self.service.calls], ["ai_start", "ai_step", "pause"])

    def test_config_during_ai_stops_before_applying_and_revokes_epoch(self):
        original = self.service.observe
        def observe():
            value = original()
            value["capabilities"]["ai_config"] = True
            return value
        self.service.observe = observe
        _, body = self.post({"type": "ai_start", "revision": 0, "budget": 10})
        start = json.loads(body)
        status, body = self.post({"type": "ai_config", "revision": 1, "stop_on_rare": True,
                                  "stop_enemy_count": 0, "talent_weights": {"T_SHOOT": 0}})
        state = json.loads(body)
        self.assertEqual(status, 200)
        self.assertEqual([c["type"] for c in self.service.calls], ["ai_start", "pause", "ai_config"])
        self.assertEqual(self.post({"type": "ai_step", "revision": state["revision"], "control_epoch": start["control_epoch"]})[0], 409)

    def test_reset_invalidates_previous_auto_epoch(self):
        status, body = self.post({"revision": 0, "type": "new_game", "seed": 7})
        self.assertEqual(status, 200)
        state = json.loads(body)
        self.assertEqual((state["revision"], state["control_epoch"]), (1, 1))
        self.assertEqual(self.post({"revision": 1, "control_epoch": 0, "type": "ai_step"})[0], 409)
        self.assertEqual([call["type"] for call in self.service.calls], ["new_game"])

    def test_known_danger_rejection_keeps_observe_available(self):
        def blocked(payload): raise ValueError("blocked_danger")
        self.service.command = blocked
        status, body = self.post({"revision": 0, "type": "wait"})
        self.assertEqual((status, json.loads(body)["error"]), (400, "blocked_danger"))
        status, body = self.request("GET", "/api/state")
        self.assertEqual((status, json.loads(body)["revision"]), (200, 1))

    def test_two_commands_same_revision_only_one_runs(self):
        barrier = threading.Barrier(3); statuses = []
        def run():
            barrier.wait(); statuses.append(self.post({"revision": 0, "type": "wait"})[0])
        threads = [threading.Thread(target=run) for _ in range(2)]
        for thread in threads: thread.start()
        barrier.wait()
        for thread in threads: thread.join()
        self.assertEqual(sorted(statuses), [200, 409])
        self.assertEqual(len(self.service.calls), 1)


if __name__ == "__main__": unittest.main()

class ServiceFactoryTests(unittest.TestCase):
    def test_engineering_adapter_rejects_actions(self):
        from unittest.mock import Mock
        from tome_mvp.service import ServiceAdapter
        bridge = Mock()
        bridge.observe.return_value = {"capabilities": {key: True for key in ("melee", "talent", "ai_start", "ai_config", "ai_template_save", "ai_template_load")}}
        adapter = ServiceAdapter(bridge, engineering_observe_only=True)
        self.assertFalse(adapter.observe()["capabilities"]["melee"])
        self.assertTrue(all(value is False for value in adapter.observe()["capabilities"].values()))
        with self.assertRaises(ValueError): adapter.command({"type": "attack", "mode": "melee"})
        bridge.command.assert_not_called()

    def test_default_headless_requires_config(self):
        from tome_mvp.service import create_service
        with self.assertRaisesRegex(ValueError, "requires --config"):
            create_service("sample", 7)

    def test_offline_and_reject_path(self):
        from unittest.mock import patch
        from tome_mvp.service import create_service
        with patch("tome_mvp.service.importlib.import_module", side_effect=ModuleNotFoundError(name="tome_mvp.bridge")):
            service = create_service("sample", 7, backend="desktop")
            self.assertFalse(service.observe()["online"])
            self.assertEqual(service.observe()["capabilities"], {})
        with self.assertRaises(ValueError): create_service("../elsewhere", 7)

    def test_factory_starts_bridge_and_closes_on_failure(self):
        from unittest.mock import patch, Mock
        from tome_mvp.service import create_service
        bridge = Mock(); module = Mock(); module.NativeBridge.return_value = bridge
        with patch("tome_mvp.service.importlib.import_module", return_value=module):
            adapter = create_service("test", 7, backend="desktop")
            self.assertIs(adapter.bridge, bridge)
            bridge.observe.return_value = {"map": {"width":64,"height":64,"rows":["@"]}, "events":["native"]}
            self.assertEqual(adapter.observe()["events"], ["native"])
            self.assertIsInstance(adapter.observe()["elapsed_ms"], int)
            bridge.start.assert_called_once_with(seed=7)
            bridge.start.side_effect = RuntimeError("failed")
            with self.assertRaises(RuntimeError): create_service("test", 8, backend="desktop")
            bridge.close.assert_called_once()
            bridge.close.reset_mock()
            bridge.start.side_effect = NotImplementedError()
            with self.assertRaises(NotImplementedError): create_service("test", 9, backend="desktop")
            bridge.close.assert_called_once()


class LifecycleTests(unittest.TestCase):
    def test_binding_failure_closes_service(self):
        from unittest.mock import Mock, patch
        from tome_mvp import server
        service = Mock()
        with patch("tome_mvp.service.create_service", return_value=service), patch("tome_mvp.server.create_server", side_effect=OSError("occupied")), patch("sys.argv", ["tome"]):
            with self.assertRaises(OSError): server.main()
        service.close.assert_called_once()

class BrowserQueueTests(unittest.TestCase):
    def test_pause_discards_queued_move_after_delayed_reply(self):
        import subprocess
        script = r'''
const fs=require("fs"),vm=require("vm"),assert=require("assert");
const nodes={}; function node(id){return nodes[id] ||= {id,dataset:{},value:id==="limit"?"10":"",options:[],replaceChildren(...v){this.options=v},textContent:"",disabled:false};}
const move=node("move"); move.dataset.move="1,0";
const wait=node("wait"); wait.dataset.command="wait";
const document={getElementById:node,querySelectorAll:s=>s==="[data-move]"?[move]:[wait],createElement:()=>({})};
let calls=[], finish;
const snapshot={revision:0,control_epoch:0,map:{width:64,height:64,rows:["@"]},party:[],enemies:[],events:[],capabilities:{move:true,wait:"true",melee:true,ranged:"true",pause:true,new_game:true}};
const reply=x=>({ok:true,json:async()=>x});
function fetch(url,opts){if(!opts || opts.method!=="POST")return Promise.resolve(reply(snapshot));const x=JSON.parse(opts.body);calls.push(x);if(calls.length===1)return new Promise(r=>finish=()=>r(reply({...snapshot,revision:1})));return Promise.resolve(reply({...snapshot,revision:2}));}
const context={document,fetch,setTimeout,console};vm.createContext(context);vm.runInContext(fs.readFileSync("tome_mvp/web/app.js","utf8"),context);
const tick=()=>new Promise(r=>setTimeout(r,0));
(async()=>{await tick();assert.equal(node("map").textContent[0],"@");assert.equal(node("melee").disabled,true);assert.equal(node("melee").title,"无可见目标");assert.equal(node("ranged").disabled,true);assert.equal(wait.disabled,true);move.onclick();await tick();move.onclick();node("pause").onclick();finish();await tick();await tick();assert.deepEqual(calls.map(x=>x.type),["move","pause"]);assert.equal(calls[1].revision,1);})().catch(e=>{console.error(e);process.exitCode=1});
'''
        result = subprocess.run(["node", "-e", script], capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        reset_script = script.replace('node("pause").onclick()', 'node("new").onclick()').replace('["move","pause"]', '["move","new_game"]')
        result = subprocess.run(["node", "-e", reset_script], capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        scene_script = script.replace('map:{width:64,height:64,rows:["@"]}', 'scene_kind:"engineering",map:{width:16,height:16,rows:["@"+".".repeat(15),...Array(15).fill(".".repeat(16))]}')
        scene_script = scene_script.replace('assert.equal(node("map").textContent[0],"@");', 'assert.equal(node("map").textContent.split("\\n").length,16);assert.equal(node("map").textContent.split("\\n")[0].length,16);assert(node("status").textContent.includes("工程场景 · 地图 16×16"));')
        result = subprocess.run(["node", "-e", scene_script], capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
