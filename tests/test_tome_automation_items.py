"""Real worker regression for ordinary items and native exploration checks."""
import json
import os
from pathlib import Path
import queue
import subprocess
import threading
import unittest

class AutomationItems(unittest.TestCase):
    def test_object_and_native_checks(self):
        build=os.environ.get('TOME_HEADLESS_BUILD_DIR')
        if not build: self.skipTest('set TOME_HEADLESS_BUILD_DIR to isolated native candidate')
        config=Path(build)/'worker_config.json'
        for seed,mode in ((11,'sweep'),(11,'explore'),(12,'sweep'),(13,'sweep')):
            with self.subTest(seed=seed,mode=mode):
                args=json.loads(config.read_text(encoding='utf8'))['worker_argv']; args[2]='/automation_item_fixture.lua'
                proc=subprocess.Popen(args,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,encoding='utf8',errors='replace')
                lines=queue.Queue(); threading.Thread(target=lambda:[lines.put(line) for line in proc.stdout],daemon=True).start(); threading.Thread(target=lambda:proc.stderr.read(),daemon=True).start()
                serial=0
                def req(method,params,g=None):
                    nonlocal serial
                    serial+=1; body={'protocol':'tome-headless-v1','id':serial,'method':method,'params':params}
                    if g is not None: body['expected_generation']=g
                    proc.stdin.write(json.dumps(body)+'\n'); proc.stdin.flush(); reply=json.loads(lines.get(timeout=45)); self.assertTrue(reply['ok'],reply); return reply['result']
                try:
                    req('create',{'seed':seed,'fixture':'exploration'}); epoch=req('act',{'type':'ai_start','mode':mode},1)['ai_epoch']; seen=[]
                    for _ in range(5):
                        obs=req('observe',{},1); seen.append((obs['party'][0]['x'],obs['party'][0]['y'],obs['ai_status'],obs['ai_stop_reason']))
                        if obs['ai_status']!='running': break
                        step=req('act',{'type':'native_ai','ai_epoch':epoch},1)
                        while step['boundary']=='pending': step=req('advance',{'budget':100},1)
                    if seed in (11,13) and mode=='sweep':
                        self.assertIn((5,3),[r[:2] for r in seen]); self.assertIn((6,2),[r[:2] for r in seen])
                    elif mode=='explore': self.assertEqual(seen[-1][3],'object seen')
                    else: self.assertEqual(seen[-1][2],'stopped')
                finally:
                    proc.stdin.close(); proc.wait(timeout=10); proc.stdout.close(); proc.stderr.close()
