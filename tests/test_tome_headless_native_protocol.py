"""Bounded contract checks for the compiled Windows headless host."""
import json
import os
from pathlib import Path
import subprocess
import threading
import queue
import unittest

ROOT = Path(__file__).resolve().parents[1]
BASE = ROOT / "artifacts/tome-headless-build-20261109"
BUILD = Path(os.environ.get("TOME_HEADLESS_BUILD_DIR", BASE / "windows-build"))
RUNTIME = BASE / "runtime"


class NativeProtocolTest(unittest.TestCase):
    def test_move_replay_block_and_unterminated_frame(self):
        exe = BUILD / 'worker_host.exe'
        if not exe.is_file(): self.skipTest('build the Windows host first')
        cmd=[str(exe),str(BUILD/'move-test-read.log'),'/worker.lua',str(ROOT/'tome_mvp/headless'),str(BUILD),str(RUNTIME/'tome'),str(RUNTIME/'engine'),str(RUNTIME/'installation/game/thirdparty'),str(RUNTIME/'installation/game')]
        def msg(i, method, params, gen=None):
            d={'protocol':'tome-headless-v1','id':i,'method':method,'params':params}
            if gen is not None: d['expected_generation']=gen
            return json.dumps(d)
        blocked=msg(3,'act',{'type':'move','dx':2,'dy':0},1)
        partial=msg(10,'act',{'type':'wait'},2)
        payload='\n'.join([msg(1,'create',{'seed':7}),msg(2,'observe',{}),blocked,blocked,msg(4,'observe',{}),msg(5,'act',{'type':'move','dx':-1,'dy':0},1),msg(6,'observe',{}),msg(7,'reset',{'seed':7},1),msg(6,'observe',{}),msg(8,'observe',{}),msg(9,'act',{'type':'wait'},1),partial])
        run=subprocess.run(cmd,input=payload,text=True,encoding='utf-8',capture_output=True,timeout=60)
        self.assertEqual(run.returncode,0,run.stderr[-1000:])
        out=[json.loads(line) for line in run.stdout.splitlines()]
        self.assertEqual(len(out),11)
        self.assertEqual(out[2]['error']['code'],'invalid_move')
        self.assertEqual(out[3]['error']['code'],'duplicate_or_old_id')
        self.assertEqual(out[1]['result'],out[4]['result'])
        self.assertTrue(out[5]['ok'],out[5])
        self.assertEqual(out[6]['result']['party'][0]['x'],out[1]['result']['party'][0]['x']-1)
        self.assertEqual(out[7]['result']['generation'],2)
        self.assertEqual(out[8]['error']['code'],'duplicate_or_old_id')
        self.assertEqual(out[9]['result']['party'],out[1]['result']['party'])
        self.assertEqual(out[9]['result']['map'],out[1]['result']['map'])
        self.assertEqual(out[9]['result']['turn'],out[1]['result']['turn'])
        self.assertEqual(out[10]['error']['code'],'stale_generation')

    def test_real_melee_reaches_decision(self):
        exe = BUILD / 'worker_host.exe'
        if not exe.is_file(): self.skipTest('build the Windows host first')
        cmd = [str(exe), str(BUILD/'melee-test-read.log'), '/worker.lua', str(ROOT/'tome_mvp/headless'), str(BUILD), str(RUNTIME/'tome'), str(RUNTIME/'engine'), str(RUNTIME/'installation/game/thirdparty'), str(RUNTIME/'installation/game')]
        proc = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, encoding='utf-8', errors='replace')
        q = queue.Queue()
        threading.Thread(target=lambda: [q.put(line) for line in proc.stdout], daemon=True).start()
        threading.Thread(target=lambda: proc.stderr.read(), daemon=True).start()
        def request(i, method, params, generation=None):
            obj={'protocol':'tome-headless-v1','id':i,'method':method,'params':params}
            if generation is not None: obj['expected_generation']=generation
            proc.stdin.write(json.dumps(obj)+'\n'); proc.stdin.flush()
            return json.loads(q.get(timeout=45))
        try:
            self.assertTrue(request(1,'create',{'seed':11})['ok'])
            before=request(2,'observe',{})['result']
            target=before['enemies'][0]
            receipt=request(3,'act',{'type':'move','dx':1,'dy':0},1)
            self.assertTrue(receipt['ok'],receipt)
            self.assertEqual(receipt['result']['boundary'],'decision')
            after=request(4,'observe',{})['result']
            self.assertGreater(after['turn'],before['turn'])
            self.assertLess(after['enemies'][0]['hp'],target['hp'])
            receipt=request(5,'act',{'type':'wait'},1)
            self.assertTrue(receipt['ok'],receipt)
            self.assertEqual(receipt['result']['boundary'],'decision')
            waited=request(6,'observe',{})['result']
            self.assertGreater(waited['turn'],after['turn'])
            self.assertLessEqual(waited['party'][0]['hp'],waited['party'][0]['max_hp'])
            start=request(7,'act',{'type':'ai_start'},1)
            receipt=request(8,'act',{'type':'native_ai','ai_epoch':start['result']['ai_epoch']},1)
            self.assertTrue(receipt['ok'],receipt)
            automated=request(9,'observe',{})['result']
            self.assertGreaterEqual(automated['turn'],waited['turn'])
        finally:
            proc.stdin.close()
            proc.wait(timeout=10)
            proc.stdout.close()
            proc.stderr.close()

    def test_native_ally_bump_displaces(self):
        exe=BUILD/'worker_host.exe'
        if not exe.is_file(): self.skipTest('candidate build unavailable')
        cmd=[str(exe),str(BUILD/'ally-bump-read.log'),'/worker.lua',str(ROOT/'tome_mvp/headless'),str(BUILD),str(RUNTIME/'tome'),str(RUNTIME/'engine'),str(RUNTIME/'installation/game/thirdparty'),str(RUNTIME/'installation/game')]
        def msg(i,method,params,gen=None):
            v={'protocol':'tome-headless-v1','id':i,'method':method,'params':params}
            if gen is not None: v['expected_generation']=gen
            return json.dumps(v)
        lines=[msg(1,'create',{'seed':7}),msg(2,'observe',{}),msg(3,'act',{'type':'move','dx':-1,'dy':1},1),msg(4,'observe',{})]
        proc=subprocess.run(cmd,input='\n'.join(lines)+'\n',capture_output=True,text=True,encoding='utf-8',errors='replace',timeout=60)
        self.assertEqual(proc.returncode,0,proc.stderr[-1000:])
        out=[json.loads(x) for x in proc.stdout.splitlines()]
        self.assertTrue(out[2]['ok'],out[2])
        before,after=out[1]['result'],out[3]['result']
        self.assertEqual((after['party'][0]['x'],after['party'][0]['y']),(before['party'][1]['x'],before['party'][1]['y']))
        self.assertGreater(after['turn'],before['turn'])

    def test_ranged_and_talent_are_native_and_reject_unknown(self):
        exe = BUILD / 'worker_host.exe'
        if not exe.is_file(): self.skipTest('candidate build unavailable')
        cmd = [str(exe), str(BUILD/'actions-read.log'), '/worker.lua', str(ROOT/'tome_mvp/headless'), str(BUILD), str(RUNTIME/'tome'), str(RUNTIME/'engine'), str(RUNTIME/'installation/game/thirdparty'), str(RUNTIME/'installation/game')]
        proc = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, encoding='utf-8', errors='replace')
        q = queue.Queue()
        threading.Thread(target=lambda: [q.put(line) for line in proc.stdout], daemon=True).start()
        threading.Thread(target=lambda: proc.stderr.read(), daemon=True).start()
        counter = 0
        def req(method, params, generation=None):
            nonlocal counter
            counter += 1
            obj={'protocol':'tome-headless-v1','id':counter,'method':method,'params':params}
            if generation is not None: obj['expected_generation']=generation
            proc.stdin.write(json.dumps(obj)+'\n'); proc.stdin.flush()
            return json.loads(q.get(timeout=45))
        try:
            self.assertTrue(req('create',{'seed':7})['ok'])
            before=req('observe',{})['result']
            self.assertEqual(before,req('observe',{})['result'])
            bad=req('act',{'type':'talent','talent':'T_FAKE','target':before['enemies'][0]['id']},1)
            self.assertEqual(bad['error']['code'],'unsupported_talent')
            shot=None
            attempts=[]
            for foe in before['enemies']:
                result=req('act',{'type':'attack','mode':'ranged','target':foe['id']},1)
                attempts.append(result)
                if result['ok']:
                    shot=result
                    break
            self.assertIsNotNone(shot,repr((before['enemies'],attempts)))
            after=req('observe',{})['result']
            self.assertEqual(after['ammo'],before['ammo']-1)
            self.assertGreater(after['turn'],before['turn'])
            self.assertTrue(any(x['id']=='T_RUSH' for x in after['talents']))
        finally:
            proc.stdin.close(); proc.wait(timeout=10); proc.stdout.close(); proc.stderr.close()

    def test_capabilities_and_rejection_are_json_only(self):
        exe = BUILD / "worker_host.exe"
        if not exe.is_file():
            self.skipTest("run scripts/build_tome_headless_windows.py first")
        cmd = [str(exe), str(BUILD / "protocol-test-read.log"), "/worker.lua", str(ROOT / "tome_mvp/headless"), str(BUILD), str(RUNTIME / "tome"), str(RUNTIME / "engine"), str(RUNTIME / "installation/game/thirdparty"), str(RUNTIME / "installation/game")]
        lines = [
            '{"protocol":"tome-headless-v1","id":1,"method":"capabilities","params":{}}',
            '{"protocol":"tome-headless-v1","id":2,"method":"act","params":{}}',
            '{"protocol":"tome-headless-v1","id":3,"id":4,"method":"capabilities","params":{}}',
            '{"protocol":"tome-headless-v1","id":5,"method":"create","params":{"seed":7}}',
            '{"protocol":"tome-headless-v1","id":6,"method":"observe","params":{}}',
            '{"protocol":"tome-headless-v1","id":7,"method":"observe","params":{}}',
        ]
        run = subprocess.run(cmd, input="\n".join(lines) + "\n", text=True, encoding="utf-8", capture_output=True, timeout=60)
        self.assertEqual(run.returncode, 0, run.stderr[-1500:])
        responses = [json.loads(line) for line in run.stdout.splitlines()]
        self.assertEqual(len(responses), 6)
        self.assertEqual(responses[0]["result"]["protocol"], "tome-headless-v1")
        self.assertTrue(responses[0]["result"]["methods"]["act"])
        self.assertEqual(responses[1]["error"]["outcome"], "rejected")
        self.assertEqual(responses[2]["error"]["code"], "invalid_request")
        self.assertTrue(responses[3]["result"]["accepted"])
        scene = responses[4]["result"]
        self.assertEqual(scene, responses[5]["result"])
        self.assertEqual(len(scene["map"]), 64)
        self.assertEqual(len(scene["party"]), 3)
        self.assertGreaterEqual(len(scene["enemies"]), 1)


if __name__ == "__main__":
    unittest.main()
