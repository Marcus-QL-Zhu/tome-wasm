"""Bounded native-worker checks for the engineering skill fixture."""
import json
import os
from pathlib import Path
import queue
import subprocess
import threading
import unittest

ROOT = Path(__file__).resolve().parents[1]
BUILD = Path(os.environ.get('TOME_HEADLESS_BUILD_DIR', ROOT / 'artifacts/tome-skill-types-20261110/build'))
RUNTIME = ROOT / 'artifacts/tome-headless-build-20261109/runtime'

class SkillTypesProtocolTest(unittest.TestCase):
    def test_fixture_grid_and_instant(self):
        exe = BUILD / 'worker_host.exe'
        if not exe.is_file(): self.skipTest('isolated Windows build missing')
        cmd = [str(exe), str(BUILD / 'skill-rpc-read.log'), '/worker.lua', str(ROOT / 'tome_mvp/headless'), str(BUILD), str(RUNTIME / 'tome'), str(RUNTIME / 'engine'), str(RUNTIME / 'installation/game/thirdparty'), str(RUNTIME / 'installation/game')]
        p = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, encoding='utf-8', errors='replace')
        q = queue.Queue(); stderr=[]
        threading.Thread(target=lambda: [q.put(line) for line in p.stdout], daemon=True).start()
        threading.Thread(target=lambda: stderr.append(p.stderr.read()), daemon=True).start()
        n=0
        def req(method, params, generation=None):
            nonlocal n
            n += 1; obj={'protocol':'tome-headless-v1','id':n,'method':method,'params':params}
            if generation is not None: obj['expected_generation']=generation
            p.stdin.write(json.dumps(obj)+'\n'); p.stdin.flush()
            try: return json.loads(q.get(timeout=45))
            except queue.Empty: self.fail('worker exited or timed out: '+''.join(stderr)[-3000:])
        try:
            result=req('create',{'seed':7,'fixture':'skill_types'}); self.assertTrue(result['ok'],result)
            before=req('observe',{})['result']; self.assertEqual(before,req('observe',{})['result'])
            skills={t['id']:t for t in before['talents']}; self.assertGreaterEqual(len(skills),10)
            self.assertEqual(skills['T_FIREFLASH']['target'],'grid'); self.assertTrue(skills['T_EVASION']['no_energy'])
            self.assertEqual(skills['T_ARCANE_POWER']['mode'],'sustained')
            bad=req('act',{'type':'talent','talent':'T_FIREFLASH','x':62,'y':62},1); self.assertFalse(bad['ok'])
            instant=req('act',{'type':'talent','talent':'T_EVASION'},1); self.assertTrue(instant['ok'],instant)
            self.assertEqual(instant['result']['action_kind'],'instant')
            after=req('observe',{})['result']; self.assertEqual(before['turn'],after['turn'])
            grid=req('act',{'type':'talent','talent':'T_FIREFLASH','x':6,'y':5},1); self.assertTrue(grid['ok'],grid)
            final=req('observe',{})['result']; self.assertGreater(final['turn'],before['turn'])
            self.assertNotEqual(before['enemies'][0]['hp'],final['enemies'][0]['hp'])
        finally:
            p.stdin.close(); p.wait(timeout=10); p.stdout.close(); p.stderr.close()

    def test_fixture_save_restore_and_reset(self):
        exe = BUILD / 'worker_host.exe'
        if not exe.is_file(): self.skipTest('isolated Windows build missing')
        cmd=[str(exe),str(BUILD/'skill-save-read.log'),'/worker.lua',str(ROOT/'tome_mvp/headless'),str(BUILD),str(RUNTIME/'tome'),str(RUNTIME/'engine'),str(RUNTIME/'installation/game/thirdparty'),str(RUNTIME/'installation/game')]
        def m(i,method,params,gen=None):
            v={'protocol':'tome-headless-v1','id':i,'method':method,'params':params}
            if gen is not None: v['expected_generation']=gen
            return v
        def run(items):
            out=subprocess.run(cmd,input=''.join(json.dumps(x,separators=(',',':'))+'\n' for x in items),capture_output=True,text=True,encoding='utf-8',errors='replace',timeout=60)
            self.assertEqual(out.returncode,0,out.stderr[-3000:])
            return [json.loads(x) for x in out.stdout.splitlines()]
        first=run([m(1,'create',{'seed':7,'fixture':'skill_types'}),m(2,'act',{'type':'wait'},1),m(3,'observe',{}),m(4,'save',{},1)])
        self.assertTrue(first[3]['ok'],first[3]); archive=first[3]['result']['archive']
        restored=run([m(1,'restore',{'archive':archive,'min_generation':2}),m(2,'observe',{}),m(3,'act',{'type':'talent','talent':'T_EVASION'},2),m(4,'act',{'type':'talent','talent':'T_FIREFLASH','x':6,'y':5},2),m(5,'reset',{'seed':7},2),m(6,'observe',{})])
        for result in restored: self.assertTrue(result['ok'],result)
        self.assertEqual(first[2]['result']['talents'],restored[1]['result']['talents'])
        self.assertEqual(restored[2]['result']['action_kind'],'instant')
        self.assertEqual(restored[5]['result']['fixture'],'skill_types')
        self.assertGreaterEqual(len(restored[5]['result']['talents']),10)

if __name__=='__main__': unittest.main()
