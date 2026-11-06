import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch
from contract import caller, identities
from files import save, sha
import runner as r
from test_contract import inherited, inputs, packet

class RunnerGuards(unittest.TestCase):
    def setUp(self):
        scratch=r.MODULE/'.terraform';scratch.mkdir(exist_ok=True)
        self.temp=tempfile.TemporaryDirectory(dir=scratch);self.root=Path(self.temp.name)
        self.v=inputs();self.variables=self.root/'inputs.json';save(self.variables,self.v)
        self.config=self.root/'aws-config';self.config.write_text('[profile pippen-sandbox]\nregion = us-west-2\ncredential_process = /usr/bin/env "synthetic-never-executed"\n')
        self.env={'AWS_PROFILE':'pippen-sandbox','AWS_CONFIG_FILE':str(self.config),'AWS_SHARED_CREDENTIALS_FILE':'/dev/null','AWS_EC2_METADATA_DISABLED':'true'}
        self.calls=[]
        def transport(args,**kwargs):
            self.calls.append(args)
            if 'get-caller-identity' in args:
                return SimpleNamespace(returncode=0,stdout=json.dumps({'Account':self.v['account_id'],'Arn':identities(self.v)['control']}))
            raise AssertionError('Unexpected synthetic boundary: '+str(args))
        self.subject=r.Runner(self.root/'execution',self.variables,'/usr/bin/true',env=self.env,transport=transport)
    def tearDown(self):self.temp.cleanup()

    def test_context_survives_for_refresh_and_fresh_sts_is_used(self):
        original=packet();raw=json.dumps(inherited(self.v,original));self.subject.env['PIPPEN_SANDBOX_CAPABILITY_CONTEXT']=raw
        _,who=self.subject.authority(original)
        self.assertEqual(who['Arn'],identities(self.v)['control'])
        self.assertEqual(self.subject.env['PIPPEN_SANDBOX_CAPABILITY_CONTEXT'],raw)
        self.assertEqual(len(self.calls),1);self.assertIn('get-caller-identity',self.calls[0])
        self.assertFalse(any('credentials-process' in args for args in self.calls))

    def test_context_tamper_blocks_before_any_cli_call(self):
        self.subject.env['PIPPEN_SANDBOX_CAPABILITY_CONTEXT']=json.dumps({**inherited(self.v,packet()),'inputs_sha256':'f'*64})
        with self.assertRaises(RuntimeError):self.subject.authority(packet())
        self.assertEqual(self.calls,[])

    def test_pending_creation_is_never_blindly_retried(self):
        save(self.subject.path('phase.json'),{'status':'pending'})
        with self.assertRaisesRegex(RuntimeError,'cannot be retried'):self.subject.apply('a'*64,'b'*64)
        self.assertEqual(self.calls,[])

    def test_static_credentials_or_backend_override_are_refused(self):
        for delta in [{'AWS_ACCESS_KEY_ID':'synthetic'},{'TF_DATA_DIR':'synthetic-other-backend'},{'TF_WORKSPACE':'other'}]:
            with self.subTest(delta=delta),self.assertRaises(RuntimeError):r.Runner(self.root/'other',self.variables,'/usr/bin/true',env={**self.env,**delta},transport=Mock())

    def test_unrelated_existing_execution_directory_is_untouched(self):
        other=self.root/'unrelated';other.mkdir(mode=0o700);evidence=other/'preserve.json';evidence.write_text('synthetic old evidence')
        with self.assertRaisesRegex(RuntimeError,'unrelated execution'):r.Runner(other,self.variables,'/usr/bin/true',env=self.env,transport=Mock())
        self.assertEqual({p.name for p in other.iterdir()},{'preserve.json'})
        self.assertEqual(evidence.read_text(),'synthetic old evidence')

    def test_selector_changed_before_credential_use_is_refused(self):
        self.subject.transport=None;self.config.write_text('changed selector')
        with self.assertRaisesRegex(RuntimeError,'selector changed'):self.subject.run(['synthetic'])

    def test_normal_child_environment_keeps_context_without_launching_process(self):
        original=packet();raw=json.dumps(inherited(self.v,original));self.subject.env['PIPPEN_SANDBOX_CAPABILITY_CONTEXT']=raw
        self.subject.transport=None
        fake=SimpleNamespace(pid=123456789,returncode=0,wait=lambda **k:None,poll=lambda:0)
        with patch.object(r.subprocess,'Popen',return_value=fake) as launch,patch.object(r.os,'killpg',side_effect=ProcessLookupError):
            self.subject.run(['synthetic'])
        self.assertEqual(launch.call_args.kwargs['env']['PIPPEN_SANDBOX_CAPABILITY_CONTEXT'],raw)
        self.assertTrue(launch.call_args.kwargs['start_new_session'])

    def test_interrupted_group_cannot_proceed_to_apply(self):
        self.subject.settled=False
        with self.assertRaisesRegex(RuntimeError,'Unsettled'):self.subject.apply('a'*64,'b'*64)
        self.assertEqual(self.calls,[])

    def test_inert_timeout_preserves_partial_logs_and_reaps_group(self):
        self.subject.transport=None
        code='import subprocess,sys,time;subprocess.Popen([sys.executable,"-c","import time;time.sleep(60)"]);print("synthetic partial",flush=True);time.sleep(60)'
        with self.assertRaises(subprocess.TimeoutExpired):self.subject.run([sys.executable,'-c',code],timeout=.3)
        records=list(self.subject.path('commands').glob('*.json'));self.assertEqual(len(records),1)
        record=json.loads(records[0].read_text());self.assertEqual(record['outcome'],'interrupted');self.assertTrue(record['process_group_absent'])
        self.assertIn('synthetic partial',records[0].with_suffix('.stdout').read_text())
        with self.assertRaises(ProcessLookupError):r.os.killpg(record['pgid'],0)

if __name__ == '__main__':unittest.main()
