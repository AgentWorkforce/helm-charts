import copy
import json
import unittest
from guest_protocol import Broker,BOOTSTRAPS,HEADS
from secret_io import SecretIoError

class Io:
    runtime_secret_arn='arn:aws:secretsmanager:us-west-2:111111111111:secret:synthetic-runtime-abcdef'
    def __init__(self):self.events=[];self.fail=None
    def deadline(self):pass
    def pending(self,step,identifier):self.events.append(('pending',step,identifier))
    def restored_auth(self):self.events.append(('restore_auth',))
    def bootstrap(self,file):
        self.events.append(('bootstrap',file['path']))
        if self.fail=='bootstrap':raise SecretIoError('synthetic_partial_bootstrap')
    def rotate(self,password):self.events.append(('rotate',))
    def publish(self,password,identifier,receipt):
        self.events.append(('publish',identifier))
        if self.fail=='publish':raise SecretIoError('synthetic_publication_timeout')
        return {'password':password,'arn':self.runtime_secret_arn,'versionId':identifier}

class Protocol(unittest.TestCase):
    def setup_broker(self,restored=False):
        scope={'phase':'restored' if restored else 'fresh','owner':'proof_admin','runtimeRole':'proof_runtime'}
        if restored:scope['restoredEvidenceSha256']='a'*64
        self.sources={'files':{'supabase/bootstrap/'+name:'1'*64 for name in BOOTSTRAPS}};self.io=Io();self.b=Broker(scope,self.sources,self.io)
    def send(self,operation,**fields):
        frame={'format':'actual-rds-io-v1','sequence':self.b.sequence+1,'operation':operation,**fields}
        r=self.b.frame(json.dumps(frame).encode());return json.loads(r) if r else None
    def bootstrap(self):
        for name in BOOTSTRAPS:self.send('bootstrap',file={'path':'supabase/bootstrap/'+name,'sha256':'1'*64,'variables':{'migration_owner':'proof_admin','runtime_role':'proof_runtime','runtime_login':'true'}})
    def receipt(self):
        return {'format':'actual-rds-guest-v1','scope':self.b.scope,'reviewedHeads':HEADS,'ok':True,'phase':'sql_verified_awaiting_parent_retirement','checks':['source_and_owner_bound','committed_bootstraps','migrate_and_idempotent_rerun','runtime_initial_tls_readiness','runtime_rotate_tls_readiness'],'errorCodes':[],'evidenceSha256':'a'*64,'runtimeRotationIds':self.b.rotations,'infrastructureRetired':False,'requiresInstanceRetirement':True}
    def full_ready(self,restored=False):
        self.setup_broker(restored)
        if restored:self.send('restored-auth')
        self.bootstrap();a=self.send('runtime',phase='initial');b=self.send('runtime',phase='rotate');self.assertNotEqual(a['password'],b['password'])
        return self.receipt()
    def test_fresh_and_restored_success_publish_after_all_readiness_and_final_gate(self):
        for restored in [False,True]:
            with self.subTest(restored=restored):
                receipt=self.full_ready(restored);published=self.send('publish',receipt=receipt,checks=self.b.before_checks())
                self.assertIsNone(self.b.result)
                reference=published['secretRef'];self.send('result',ok=True,receipt=receipt,checks=self.b.before_checks()+['exact_persisted_version_fresh_tls_readiness'],secretRef=reference)
                self.assertTrue(self.b.result['ok'])
                self.assertTrue(all('password' not in str(e) for e in self.io.events))
                for i,event in enumerate(self.io.events):
                    if event[0] in ['bootstrap','rotate','publish']:self.assertEqual(self.io.events[i-1][0],'pending')
                if restored:self.assertEqual(self.io.events[0],('restore_auth',))
    def test_restore_auth_is_required_before_any_mutation(self):
        self.setup_broker(True)
        with self.assertRaisesRegex(SecretIoError,'restore_auth_before_mutation'):self.bootstrap()
        self.assertEqual(self.io.events,[])
    def test_unknown_bootstrap_and_duplicate_sequence_block_before_mutation(self):
        self.setup_broker()
        with self.assertRaises(SecretIoError):self.send('bootstrap',file={'path':'unreviewed.sql','sha256':'1'*64,'variables':{}})
        self.assertEqual(self.io.events,[])
        self.setup_broker();self.bootstrap()
        with self.assertRaisesRegex(SecretIoError,'sequence'):self.b.frame(json.dumps({'format':'actual-rds-io-v1','sequence':self.b.sequence,'operation':'runtime','phase':'initial'}).encode())
        with self.assertRaisesRegex(SecretIoError,'already_complete'):self.send('runtime',phase='initial')
    def test_publication_requires_both_rotations_and_complete_receipt(self):
        self.setup_broker();self.bootstrap();self.send('runtime',phase='initial')
        with self.assertRaisesRegex(SecretIoError,'publication_order'):self.send('publish',receipt=self.receipt(),checks=[])
        self.assertFalse(any(x[0]=='publish' for x in self.io.events))
        for mutate in ['receipt','checks','catalog']:
            receipt=self.full_ready(restored=True);checks=self.b.before_checks()
            if mutate=='receipt':receipt['checks']=receipt['checks'][:-1]
            if mutate=='checks':checks=checks[:-1]
            if mutate=='catalog':receipt['evidenceSha256']='b'*64
            with self.subTest(mutate=mutate),self.assertRaises(SecretIoError):self.send('publish',receipt=receipt,checks=checks)
            self.assertFalse(any(x[0]=='publish' for x in self.io.events))
    def test_partial_sql_and_ambiguous_secret_write_leave_pending_and_quarantine(self):
        self.setup_broker();self.io.fail='bootstrap'
        with self.assertRaisesRegex(SecretIoError,'partial_bootstrap'):self.bootstrap()
        self.assertEqual(self.io.events[0][0:2],('pending','bootstrap'))
        with self.assertRaisesRegex(SecretIoError,'already_complete'):self.bootstrap()
        receipt=self.full_ready();self.io.fail='publish'
        with self.assertRaisesRegex(SecretIoError,'publication_timeout'):self.send('publish',receipt=receipt,checks=self.b.before_checks())
        self.assertEqual(self.io.events[-2][0:2],('pending','publish'));self.assertIsNone(self.b.result)
        with self.assertRaisesRegex(SecretIoError,'already_complete'):self.send('publish',receipt=receipt,checks=self.b.before_checks())
    def test_duplicate_json_keys_refused_without_io(self):
        self.setup_broker()
        with self.assertRaisesRegex(SecretIoError,'duplicate_key'):self.b.frame(b'{"format":"actual-rds-io-v1","sequence":1,"sequence":2,"operation":"runtime"}')
        self.assertEqual(self.io.events,[])
    def test_persisted_readiness_missing_cannot_be_success(self):
        receipt=self.full_ready();reference=self.send('publish',receipt=receipt,checks=self.b.before_checks())['secretRef']
        with self.assertRaisesRegex(SecretIoError,'persisted_readiness_missing'):self.send('result',ok=True,receipt=receipt,checks=self.b.before_checks(),secretRef=reference)
        self.assertIsNone(self.b.result)
if __name__=='__main__':unittest.main()
