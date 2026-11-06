import importlib.util
import json
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest.mock import patch
from secret_io import SecretIoError
spec=importlib.util.spec_from_file_location('rds_host',Path(__file__).with_name('verify-host.py'));h=importlib.util.module_from_spec(spec);spec.loader.exec_module(h)
ARN='arn:aws:secretsmanager:us-west-2:111111111111:secret:synthetic-runtime-abcdef'
VERSION='00000000-0000-4000-8000-000000000000'
class Host(unittest.TestCase):
    def cfg(self):return {'deadline':'2099-01-01T00:00:00.000Z','region':'us-west-2','account_id':'111111111111','runtime_secret_arn':ARN,'source_sha':'0'*40,'expected_tags':{'pippen:session':VERSION},'guest_sources':{'composition_commit':'1'*40,'manifest_sha256':'2'*64,'generation':'3'*64},'database':'applicationproof','runtime_role':'proof_runtime','phase':'seed'}
    def test_get_secret_requires_requested_historical_version_and_exact_arn(self):
        c=self.cfg();body={'username':'proof_admin','password':'synthetic-only-canary'}
        value={'ARN':ARN,'VersionId':VERSION,'SecretString':json.dumps(body)}
        with patch.object(h,'cli',return_value=value) as call:
            self.assertEqual(h.secret(c,ARN,VERSION),(body,VERSION));self.assertIn('--version-id',call.call_args.args)
        for changed in [{'ARN':ARN+'foreign'},{'VersionId':'11111111-1111-4111-8111-111111111111'}]:
            with self.subTest(changed=changed),patch.object(h,'cli',return_value={**value,**changed}),self.assertRaises(SecretIoError):h.secret(c,ARN,VERSION)
    def test_publication_keeps_value_only_in_private_stdin_and_pins_roundtrip(self):
        c=self.cfg();source={'DBInstanceArn':'arn:aws:rds:us-west-2:111111111111:db:synthetic','DbiResourceId':'db-SYNTHETIC'}
        io=h.HostIo(c,Path('.'),'synthetic-owner',source,source,{})
        password='synthetic-runtime-value-never-in-argv'
        stored=io.runtime_value(password);responses=[{'ARN':ARN,'VersionId':VERSION},{'ARN':ARN,'VersionId':VERSION,'SecretString':json.dumps(stored)}]
        with patch.object(h,'cli',side_effect=responses) as call:
            result=io.publish(password,VERSION,{})
            self.assertEqual(result,{'password':password,'arn':ARN,'versionId':VERSION})
            first=call.call_args_list[0];self.assertNotIn(password,repr(first.args));self.assertIn('--client-request-token',first.args);self.assertIn('file:///dev/stdin',first.args);self.assertIn(password.encode(),first.kwargs['private_input'])
            self.assertEqual(call.call_args_list[1].args[-2:],('--version-id',VERSION))
        with patch.object(h,'cli',return_value={'ARN':ARN,'VersionId':'different'}) as call,self.assertRaisesRegex(SecretIoError,'published_secret_reference'):io.publish(password,VERSION,{})
        self.assertEqual(call.call_count,1)
    def test_refusal_cannot_accept_nested_credential_api_error(self):
        c=self.cfg();error=b'An error occurred (AccessDenied) when calling the AssumeRole operation'
        with patch.object(h,'run',return_value=SimpleNamespace(returncode=1,stdout=b'',stderr=error)),self.assertRaisesRegex(SecretIoError,'target_refusal'):h.cli(c,'s3api','get-object','--bucket','synthetic',refusal='AccessDenied')
    def test_expired_deadline_refuses_before_any_child(self):
        c=self.cfg();c['deadline']='2000-01-01T00:00:00.000Z'
        with patch.object(h,'run') as child,self.assertRaisesRegex(SecretIoError,'expired'):h.cli(c,'secretsmanager','get-secret-value','--secret-id',ARN)
        child.assert_not_called()
if __name__=='__main__':unittest.main()
