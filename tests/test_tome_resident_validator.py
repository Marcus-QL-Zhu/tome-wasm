import json
from pathlib import Path
import shutil
import tempfile
import unittest

from tome_mvp.wasm.resident_validator import ResidentValidator


@unittest.skipUnless(shutil.which('node'), 'node required')
class ResidentValidatorTests(unittest.TestCase):
    def setUp(self):
        root = Path(__file__).resolve().parents[1] / 'artifacts'
        root.mkdir(exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(prefix='resident-transport-test-', dir=root)
        self.root = Path(self.temp.name)
        self.script = self.root / 'fixture.mjs'
        self.script.write_text("""
import {createInterface} from 'node:readline';
for await (const line of createInterface({input:process.stdin})) {
 const {id,request}=JSON.parse(line);
 if(request.exit)process.exit(3);
 if(request.timeout){await new Promise(r=>setTimeout(r,10000));}
 process.stdout.write(JSON.stringify({id:request.bad?id+1:id,result:{ok:!request.failed,pid:process.pid,value:request.value}})+'\\n');
}
""", encoding='utf-8')
        self.client = ResidentValidator(self.root, self.script, timeout=2, idle_seconds=30)

    def tearDown(self):
        self.client.close()
        self.temp.cleanup()

    def test_reuse_and_idle_disposal(self):
        first = self.client.request({'value': 'first'})
        second = self.client.request({'value': 'second'})
        self.assertEqual(first['pid'], second['pid'])
        self.assertEqual(second['value'], 'second')
        self.client.last_used -= 31
        self.client.expire()
        self.assertIsNone(self.client.process)
        third = self.client.request({'value': 'third'})
        self.assertNotEqual(first['pid'], third['pid'])

    def test_mismatch_discards_worker_and_next_request_recovers(self):
        first = self.client.request({})
        with self.assertRaisesRegex(RuntimeError, 'invalid resident'):
            self.client.request({'bad': True})
        self.assertIsNone(self.client.process)
        second = self.client.request({})
        self.assertNotEqual(first['pid'], second['pid'])

    def test_reported_failure_discards_process(self):
        first=self.client.request({})
        failed=self.client.request({'failed':True})
        self.assertFalse(failed['ok'])
        self.assertIsNone(self.client.process)
        self.assertNotEqual(first['pid'],self.client.request({})['pid'])

    def test_exit_does_not_hang(self):
        with self.assertRaisesRegex(RuntimeError, 'exited'):
            self.client.request({'exit': True})
        self.assertIsNone(self.client.process)

    def test_timeout_discards_worker(self):
        self.client.request({})
        self.client.timeout = 0.1
        import queue
        with self.assertRaises(queue.Empty):
            self.client.request({'timeout': True})
        self.assertIsNone(self.client.process)

    def test_close_is_final(self):
        self.client.close()
        with self.assertRaisesRegex(RuntimeError, 'closed'):
            self.client.request({})

    def test_different_scripts_with_equal_mtime_have_distinct_protocols(self):
        import os
        from unittest.mock import patch
        from tome_mvp.wasm import resident_validator as pool
        public=self.root/'package'/'public'
        public.mkdir(parents=True)
        (public.parent/'identity.json').write_text('{}',encoding='utf8')
        scripts=[]
        for protocol in ('legacy','partition'):
            script=public.parent/(protocol+'.mjs')
            script.write_text("import {createInterface} from 'node:readline';\n"
                "for await(const line of createInterface({input:process.stdin})){"
                "const {id}=JSON.parse(line);"
                "process.stdout.write(JSON.stringify({id,result:{ok:true,protocol:"
                +json.dumps(protocol)+"}})+'\\n');}\n",encoding='utf8')
            os.utime(script,ns=(1_700_000_000_000_000_000,1_700_000_000_000_000_000))
            scripts.append(script)
        with patch.object(pool,'_pool',{}):
            try:
                a=pool.validator_for(self.root/'same.sqlite',public,scripts[0])
                b=pool.validator_for(self.root/'same.sqlite',public,scripts[1])
                self.assertIsNot(a,b)
                self.assertEqual(a.request({})['protocol'],'legacy')
                self.assertEqual(b.request({})['protocol'],'partition')
            finally:pool.close_all()

    def test_idle_reaper_releases_without_next_request_but_preserves_lease(self):
        import threading,time
        from unittest.mock import patch
        from tome_mvp.wasm import resident_validator as pool
        self.client.idle_seconds=0.05
        self.client.request({})
        self.client.pool_pins=1
        stop=threading.Event()
        with patch.object(pool,'_pool',{'isolated-test':self.client}):
            thread=threading.Thread(target=pool._reaper_loop,args=(stop,0.02))
            thread.start()
            try:
                time.sleep(0.15)
                self.assertIsNotNone(self.client.process)
                self.assertIsNone(self.client.process.poll())
                with pool._pool_lock:self.client.pool_pins=0
                deadline=time.monotonic()+2
                while time.monotonic()<deadline:
                    with self.client.lock:
                        if self.client.process is None:break
                    time.sleep(0.01)
                with self.client.lock:self.assertIsNone(self.client.process)
                # Expiry discards disposable memory; the client can cold-start.
                self.assertTrue(self.client.request({})['ok'])
            finally:
                stop.set();thread.join(timeout=2)
                self.assertFalse(thread.is_alive())
