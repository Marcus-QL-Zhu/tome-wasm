import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
from tome_mvp.service import ServiceAdapter

class FakeBridge:
    def __init__(self, argv=None, timeout=1, startup_timeout=1):
        self.argv=argv or ['fake']; self.timeout=timeout; self.startup_timeout=startup_timeout
        self.generation=1; self.boundary='decision'; self.closed=False; self.fail=False; self.worker_capabilities={"methods":{"restore":True}}; self.process=None
    def start(self, seed=7, empty=False): pass
    def _set_generation(self, result): self.generation=result['generation']
    def _receipt(self, result): self.boundary=result['boundary']
    def observe(self): return {'generation':self.generation,'capabilities':{'save':True,'load':True}}
    def request(self, method, params, expected_generation=None, timeout=None):
        if method=='save': return {'archive':{'format':'tome-headless-snapshot-v1','generation':self.generation,'seed':7,'snapshot':{}}}
        if self.fail: raise RuntimeError('restore failed')
        return {'accepted':True,'generation':max(params['min_generation'],params['archive']['generation']+1),'boundary':'decision'}
    def close(self): self.closed=True

class SaveTests(unittest.TestCase):
    def test_fixed_slot_repeat_load_and_failure_keeps_old(self):
        with tempfile.TemporaryDirectory() as directory:
            slot=Path(directory)/'slot.json'; original=FakeBridge(); service=ServiceAdapter(original,save_session='test')
            with patch.object(service,'_slot_path',return_value=slot), patch('tome_mvp.headless_bridge.HeadlessBridge',FakeBridge):
                self.assertFalse(service.observe()['capabilities']['load'])
                service.command({'type':'save'}); self.assertTrue(slot.is_file())
                self.assertEqual(service.command({'type':'load'})['generation'],2)
                self.assertTrue(original.closed)
                self.assertEqual(service.command({'type':'load'})['generation'],3)
                current=service.bridge
                class Broken(FakeBridge):
                    def request(self,*a,**kw): raise RuntimeError('failed')
                with patch('tome_mvp.headless_bridge.HeadlessBridge',Broken):
                    with self.assertRaises(RuntimeError): service.command({'type':'load'})
                self.assertIs(service.bridge,current); self.assertFalse(current.closed)
                with self.assertRaises(ValueError): service.command({'type':'load','path':'other'})

    def test_save_explicitly_stops_ai_before_native_save(self):
        with tempfile.TemporaryDirectory() as directory:
            slot=Path(directory)/'slot.json'; bridge=FakeBridge(); bridge.worker_capabilities['methods']['ai_stop']=True
            bridge.boundary='decision'; calls=[]
            def request(method,params,expected_generation=None,timeout=None):
                calls.append((method,params))
                if method=='act': return {'accepted':True,'generation':1,'boundary':'decision'}
                return {'archive':{'format':'tome-headless-snapshot-v1','generation':1,'seed':7,'snapshot':{}}}
            bridge.request=request
            bridge._receipt=lambda result: None
            service=ServiceAdapter(bridge,save_session='test')
            with patch.object(service,'_slot_path',return_value=slot): service.command({'type':'save'})
            self.assertEqual(calls,[('act',{'type':'ai_stop'}),('save',{})])

    def test_dead_worker_can_only_load_existing_slot(self):
        with tempfile.TemporaryDirectory() as directory:
            slot=Path(directory)/'slot.json'; original=FakeBridge(); service=ServiceAdapter(original,save_session='test')
            with patch.object(service,'_slot_path',return_value=slot), patch('tome_mvp.headless_bridge.HeadlessBridge',FakeBridge):
                service.command({'type':'save'})
                class Dead:
                    def poll(self): return 1
                original.process=Dead()
                original.observe=lambda: (_ for _ in ()).throw(RuntimeError('worker exited'))
                offline=service.observe()
                self.assertFalse(offline['online']); self.assertEqual(offline['capabilities'],{'load':True})
                self.assertEqual(offline['map'],[])
                self.assertEqual(service.command({'type':'load'})['generation'],2)

if __name__=='__main__': unittest.main()
