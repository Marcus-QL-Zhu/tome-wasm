"""Native automation modes, against an isolated worker candidate."""
import json, os, queue, subprocess, threading, unittest
from pathlib import Path

class NativeModes(unittest.TestCase):
    def test_modes(self):
        config=Path(os.environ['TOME_HEADLESS_BUILD_DIR'])/'worker_config.json'
        args=json.loads(config.read_text(encoding='utf8'))['worker_argv']
        args[1]=str(config.parent/'automation-test.log')
        if os.environ.get('TOME_AUTOMATION_HEALTH'): args[2]='/automation_health_fixture.lua'
        p=subprocess.Popen(args,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,encoding='utf8',errors='replace')
        lines=queue.Queue(); threading.Thread(target=lambda:[lines.put(x) for x in p.stdout],daemon=True).start(); threading.Thread(target=lambda:p.stderr.read(),daemon=True).start()
        i=0
        def req(method,params,g=None):
            nonlocal i
            i+=1; d={'protocol':'tome-headless-v1','id':i,'method':method,'params':params}
            if g is not None: d['expected_generation']=g
            p.stdin.write(json.dumps(d)+'\n');p.stdin.flush(); return json.loads(lines.get(timeout=45))
        try:
            self.assertTrue(req('create',{'seed':11,'fixture':'recovery'})['ok'])
            caps=req('capabilities',{})['result']; self.assertEqual(caps['ai_modes'],['sweep','explore','rest'])
            self.assertEqual(req('act',{'type':'ai_start','mode':'bad'},1)['error']['code'],'invalid_ai_mode')
            if os.environ.get('TOME_AUTOMATION_HEALTH'):
                start=req('act',{'type':'ai_start','mode':'explore'},1)['result']; epoch=start['ai_epoch']
                self.assertTrue(req('act',{'type':'native_ai','ai_epoch':epoch},1)['ok'])
                denied=req('act',{'type':'ai_start','mode':'explore'},1); self.assertFalse(denied['ok']); self.assertEqual(denied['error']['code'],'health_confirmation_required')
                obs=req('observe',{},1)['result']; self.assertEqual(obs['ai_epoch'],epoch); self.assertEqual(obs['ai_stop_reason'],'health_alert'); self.assertEqual(obs['ai_alert'][0]['percent'],20)
                start=req('act',{'type':'ai_start','mode':'explore'},1)['result']; epoch=start['ai_epoch']
                self.assertTrue(req('act',{'type':'native_ai','ai_epoch':epoch},1)['ok'])
                obs=req('observe',{},1)['result']; self.assertNotEqual(obs['ai_stop_reason'],'health_alert')
                if obs['ai_status']=='running': self.assertTrue(req('act',{'type':'ai_stop'},1)['ok'])
                return
            for mode in ('rest','explore','sweep'):
                start=req('act',{'type':'ai_start','mode':mode},1); self.assertTrue(start['ok'],start)
                epoch=start['result']['ai_epoch']; obs=req('observe',{},1)['result']; self.assertEqual(obs['ai_mode'],mode)
                step=req('act',{'type':'native_ai','ai_epoch':epoch},1); self.assertTrue(step['ok'],step)
                obs=req('observe',{},1)['result']
                if obs['ai_status']=='running': self.assertTrue(req('act',{'type':'ai_stop'},1)['ok'])
                self.assertEqual(req('act',{'type':'native_ai','ai_epoch':epoch},1)['error']['code'],'ai_not_authorized')
                saved=req('save',{},1); self.assertTrue(saved['ok'],saved)
        finally:
            p.stdin.close();p.wait(timeout=10);p.stdout.close();p.stderr.close()
