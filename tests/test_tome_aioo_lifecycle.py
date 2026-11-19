"""Native AIoo authorization and stop boundary regression."""
import json
import os
from pathlib import Path
import queue
import subprocess
import threading
import unittest

ROOT = Path(__file__).resolve().parents[1]
BUILD = Path(os.environ.get('TOME_HEADLESS_BUILD_DIR', ROOT / 'artifacts/tome-aioo-complete-20261110/candidate'))

class AiooLifecycleTest(unittest.TestCase):
    def test_native_stop_revokes_epoch(self):
        config = BUILD / 'worker_config.json'
        if not config.is_file(): self.skipTest('candidate worker unavailable')
        args = json.loads(config.read_text(encoding='utf8'))['worker_argv']
        args[1] = str(BUILD / 'lifecycle-test-read.log')
        p = subprocess.Popen(args, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, encoding='utf8', errors='replace')
        lines = queue.Queue()
        threading.Thread(target=lambda: [lines.put(line) for line in p.stdout], daemon=True).start()
        threading.Thread(target=lambda: p.stderr.read(), daemon=True).start()
        counter = 0
        def req(method, params, generation=None):
            nonlocal counter
            counter += 1
            data = {'protocol':'tome-headless-v1','id':counter,'method':method,'params':params}
            if generation is not None: data['expected_generation'] = generation
            p.stdin.write(json.dumps(data)+'\n'); p.stdin.flush()
            return json.loads(lines.get(timeout=45))
        try:
            self.assertTrue(req('create',{'seed':11})['ok'])
            self.assertEqual(req('act',{'type':'native_ai','ai_epoch':1},1)['error']['code'],'ai_not_authorized')
            config={'stop_on_rare':True,'stop_enemy_count':1,'talent_weights':{}}
            self.assertTrue(req('act',{'type':'ai_config','config':config},1)['ok'])
            before=req('observe',{},1)['result']
            start=req('act',{'type':'ai_start'},1)['result']; epoch=start['ai_epoch']
            result=req('act',{'type':'native_ai','ai_epoch':epoch},1)
            self.assertTrue(result['ok'],result)
            obs=req('observe',{},1)['result']
            self.assertEqual(obs['ai_status'],'stopped')
            self.assertRegex(obs['ai_stop_reason'],r'^#RED#AI stopped: [1-9][0-9]* enemies spotted \(Limit: 1\)!$')
            self.assertEqual(obs['turn'],before['turn'])
            self.assertFalse(obs['capabilities']['ai_step'])
            turn=obs['turn']
            self.assertEqual(req('act',{'type':'native_ai','ai_epoch':epoch},1)['error']['code'],'ai_not_authorized')
            self.assertEqual(req('observe',{},1)['result']['turn'],turn)
            config['stop_enemy_count']=0
            self.assertTrue(req('act',{'type':'ai_config','config':config},1)['ok'])
            start=req('act',{'type':'ai_start'},1)['result']
            self.assertGreater(start['ai_epoch'],epoch)
            self.assertEqual(req('act',{'type':'native_ai','ai_epoch':epoch},1)['error']['code'],'ai_not_authorized')
            resumed=req('act',{'type':'native_ai','ai_epoch':start['ai_epoch']},1)
            self.assertTrue(resumed['ok'],resumed)
            self.assertTrue(req('act',{'type':'ai_stop'},1)['ok'])
            self.assertTrue(req('reset',{'seed':11},1)['ok'])
            self.assertEqual(req('act',{'type':'native_ai','ai_epoch':start['ai_epoch']},1)['error']['code'],'stale_generation')
        finally:
            p.stdin.close(); p.wait(timeout=10); p.stdout.close(); p.stderr.close()
