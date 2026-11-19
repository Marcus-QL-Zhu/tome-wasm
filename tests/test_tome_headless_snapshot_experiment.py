"""Experimental persistence verification; does not imply a public save API."""
import json
import os
from pathlib import Path
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]
BUILD = Path(os.environ.get('TOME_HEADLESS_BUILD_DIR', ROOT / 'artifacts/tome-native-expansion-20261109/candidate'))


class SnapshotExperimentTest(unittest.TestCase):
    def command(self, script):
        config = BUILD / 'worker_config.json'
        if not config.is_file():
            self.skipTest('candidate build unavailable')
        argv = json.loads(config.read_text(encoding='utf-8'))['worker_argv']
        argv[1] = str(BUILD / 'snapshot-experiment-read.log')
        argv[2] = '/' + script
        return argv

    def run_probe(self, script, payload=None):
        proc = subprocess.run(self.command(script), input=payload, capture_output=True,
                              text=True, encoding='utf-8', errors='replace', timeout=120)
        self.assertEqual(proc.returncode, 0, proc.stderr[-3000:])
        return proc.stdout

    def test_protocol_save_and_restore_generation(self):
        def msg(i, method, params, generation=None):
            d = {'protocol': 'tome-headless-v1', 'id': i, 'method': method, 'params': params}
            if generation is not None:
                d['expected_generation'] = generation
            return d

        def run(messages):
            data = ''.join(json.dumps(x, separators=(',', ':')) + '\n' for x in messages)
            proc = subprocess.run(self.command('worker.lua'), input=data, capture_output=True,
                                  text=True, encoding='utf-8', errors='replace', timeout=120)
            self.assertEqual(proc.returncode, 0, proc.stderr[-2000:])
            return [json.loads(x) for x in proc.stdout.splitlines()]

        actions = [msg(1, 'create', {'seed': 11}), msg(2, 'act', {'type': 'wait'}, 1),
                   msg(3, 'save', {}, 1), msg(4, 'observe', {})]
        for i in range(3):
            actions += [msg(5 + i*2, 'act', {'type': 'wait'}, 1), msg(6 + i*2, 'observe', {})]
        original = run(actions)
        self.assertTrue(original[2]['ok'], original[2])
        archive = original[2]['result']['archive']
        restore_actions = [msg(1, 'restore', {'archive': archive, 'min_generation': 5}),
                           msg(2, 'observe', {}), msg(3, 'act', {'type': 'wait'}, 1)]
        for i in range(3):
            restore_actions += [msg(4 + i*2, 'act', {'type': 'wait'}, 5), msg(5 + i*2, 'observe', {})]
        restore_actions += [msg(10, 'save', {}, 5)]
        restored = run(restore_actions)
        self.assertEqual(restored[0]['result']['generation'], 5)
        self.assertEqual(restored[2]['error']['code'], 'stale_generation')
        for before, after in zip([original[3], original[5], original[7], original[9]],
                                 [restored[1], restored[4], restored[6], restored[8]]):
            for key in ('map', 'party', 'enemies', 'turn', 'status'):
                self.assertEqual(before['result'][key], after['result'][key], key)
        self.assertTrue(restored[9]['ok'], restored[9])
        twice = run([msg(1, 'restore', {'archive': restored[9]['result']['archive'], 'min_generation': 6}), msg(2, 'observe', {})])
        self.assertEqual(twice[0]['result']['generation'], 6)
        for key in ('map', 'party', 'enemies', 'turn', 'status'):
            self.assertEqual(restored[8]['result'][key], twice[1]['result'][key], key)
        old = run([msg(1, 'restore', {'archive': archive, 'min_generation': 7})])
        self.assertEqual(old[0]['result']['generation'], 7)

    def test_human_death_native_path(self):
        self.assertIn('PASS_NATIVE_HUMAN_DEATH_AND_EMPTY_ENEMIES', self.run_probe('death_probe.lua'))

    def test_rush_cost_and_cooldown_cross_process(self):
        saved=self.run_probe('snapshot_rush_export_probe.lua')
        self.assertIn('PASS_RUSH_CROSS_PROCESS_THREE_WAITS', self.run_probe('snapshot_rush_import_probe.lua',saved))

    def test_shared_fov_concealment_and_wall(self):
        self.assertIn('PASS_SHARED_FOV_AND_CONCEALMENT', self.run_probe('visibility_probe.lua'))

    def test_aioo_stopped_state_cross_process(self):
        def msg(i, method, params, generation=None):
            d={'protocol':'tome-headless-v1','id':i,'method':method,'params':params}
            if generation is not None: d['expected_generation']=generation
            return d
        def run(messages):
            payload=''.join(json.dumps(x,separators=(',',':'))+'\n' for x in messages)
            proc=subprocess.run(self.command('worker.lua'),input=payload,capture_output=True,text=True,
                                encoding='utf-8',errors='replace',timeout=120)
            self.assertEqual(proc.returncode,0,proc.stderr[-2000:])
            return [json.loads(x) for x in proc.stdout.splitlines()]
        seq=[msg(1,'create',{'seed':11}),msg(2,'act',{'type':'ai_start'},1),
             msg(3,'act',{'type':'native_ai','ai_epoch':1},1),msg(4,'act',{'type':'ai_stop'},1),msg(5,'save',{},1),
             msg(6,'act',{'type':'ai_start'},1),msg(7,'act',{'type':'native_ai','ai_epoch':2},1),
             msg(8,'act',{'type':'ai_stop'},1),msg(9,'observe',{})]
        result=run(seq)
        for item in result: self.assertTrue(item['ok'],item)
        archive=result[4]['result']['archive']
        restored=run([msg(1,'restore',{'archive':archive,'min_generation':2}),
                      msg(2,'act',{'type':'ai_start'},2),msg(3,'act',{'type':'native_ai','ai_epoch':2},2),
                      msg(4,'act',{'type':'ai_stop'},2),msg(5,'observe',{})])
        for item in restored: self.assertTrue(item['ok'],item)
        for key in ('map','party','enemies','turn','status','ammo','talents'):
            self.assertEqual(result[-1]['result'][key],restored[-1]['result'][key],key)

    def test_cross_process_three_waits(self):
        exported = self.run_probe('snapshot_export_probe.lua')
        self.assertIn('PASS_EXPERIMENT_CROSS_PROCESS_THREE_WAITS',
                      self.run_probe('snapshot_import_probe.lua', exported))


if __name__ == '__main__':
    unittest.main()
