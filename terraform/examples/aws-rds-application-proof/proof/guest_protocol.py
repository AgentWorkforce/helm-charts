"""Closed trusted host dialogue. No subprocess/AWS/credential lookup on import.

IO implementations carry private values only in memory/stdin. This state machine
is not remote execution authority, an IAM fence or an untrusted guest sandbox.
"""
import hashlib
import json
import re
import secrets
import uuid
from secret_io import SecretIoError

BOOTSTRAPS=['rds_owner_function_default_revoke.sql','rds_migration_roles.sql','hoopdb_runtime_role_rds.sql','session_directory_search_worker.sql','session_token_verifier.sql','session_ingest_roles.sql']
HEADS={'rds':'623400709a030cbed39ffbe7a77d76b04ae26e54','portable':'19101f78742cd4173dd55ee26aac2dfd49d6202c'}
UUID=r'[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}'
def require(v,code):
    if not v:raise SecretIoError(code)

def sealed_receipt(value,scope,rotations):
    require(isinstance(value,dict) and set(value)=={'format','scope','reviewedHeads','ok','phase','checks','errorCodes','evidenceSha256','runtimeRotationIds','infrastructureRetired','requiresInstanceRetirement'},'guest_receipt_shape')
    require(value['format']=='actual-rds-guest-v1' and value['scope']==scope and value['reviewedHeads']==HEADS and value['ok'] is True and value['phase']=='sql_verified_awaiting_parent_retirement','guest_receipt_scope')
    require(value['checks']==['source_and_owner_bound','committed_bootstraps','migrate_and_idempotent_rerun','runtime_initial_tls_readiness','runtime_rotate_tls_readiness'] and value['errorCodes']==[] and value['runtimeRotationIds']==rotations and value['infrastructureRetired'] is False and value['requiresInstanceRetirement'] is True,'guest_receipt_incomplete')
    require(isinstance(value['evidenceSha256'],str) and re.fullmatch(r'[a-f0-9]{64}',value['evidenceSha256']),'guest_evidence_hash')
    if scope['phase']=='restored':require(value['evidenceSha256']==scope['restoredEvidenceSha256'],'guest_restored_catalog_changed')

class Broker:
    """IO has deadline(), pending(step,id), bootstrap(file), rotate(password),
    publish(password,id,receipt)->{password,arn,versionId}. All operations bounded.
    pending() MUST durably publish only nonsecret intent before any SQL/SM write.
    """
    def __init__(self,scope,sources,io):
        self.scope=scope;self.sources=sources;self.io=io;self.sequence=0;self.bootstrap_index=0;self.rotations=[];self.password=None;self.published=None;self.result=None;self.failed=False;self.restored_ready=scope['phase']!='restored'
    def before_checks(self):
        values=['wrong_hostname_tls_refused','wrong_ca_tls_refused']
        if self.scope['phase']=='restored':values+=['seed_version_fresh_tls_readiness_BEFORE_bootstrap_or_rotation','old_initial_password_exact_28P01']
        return values+['old_rotate_password_exact_28P01']
    def frame(self,line):
        require(not self.failed and self.result is None,'guest_protocol_already_complete')
        try:return self._frame(line)
        except BaseException:
            self.failed=True
            raise
    def _frame(self,line):
        self.io.deadline();require(isinstance(line,bytes) and len(line)<=65536,'guest_frame_bound')
        def unique(pairs):
            value={}
            for key,item in pairs:
                require(key not in value,'guest_frame_duplicate_key');value[key]=item
            return value
        try:v=json.loads(line,object_pairs_hook=unique)
        except SecretIoError:raise
        except Exception:raise SecretIoError('guest_frame_json') from None
        require(isinstance(v,dict) and v.get('format')=='actual-rds-io-v1' and type(v.get('sequence')) is int and v['sequence']==self.sequence+1,'guest_frame_sequence')
        op=v.get('operation');self.sequence=v['sequence'];answer={'format':'actual-rds-io-v1','sequence':self.sequence,'ok':True}
        if op=='restored-auth':
            require(set(v)=={'format','sequence','operation'} and self.scope['phase']=='restored' and not self.restored_ready and self.bootstrap_index==0 and not self.rotations,'restore_auth_order')
            self.io.restored_auth();self.restored_ready=True
        elif op=='bootstrap':
            require(self.restored_ready,'restore_auth_before_mutation')
            require(set(v)=={'format','sequence','operation','file'} and self.bootstrap_index<len(BOOTSTRAPS) and not self.rotations and self.published is None,'bootstrap_order')
            name='supabase/bootstrap/'+BOOTSTRAPS[self.bootstrap_index];f=v['file']
            require(isinstance(f,dict) and set(f)=={'path','sha256','variables'} and f['path']==name and f['sha256']==self.sources['files'].get(name) and f['variables']=={'migration_owner':self.scope['owner'],'runtime_role':self.scope['runtimeRole'],'runtime_login':'true'},'bootstrap_payload_refused')
            self.io.pending('bootstrap',str(uuid.uuid4()));self.io.bootstrap(f);self.bootstrap_index+=1
        elif op=='runtime':
            require(set(v)=={'format','sequence','operation','phase'} and self.bootstrap_index==len(BOOTSTRAPS) and self.published is None and len(self.rotations)<2 and v['phase']==['initial','rotate'][len(self.rotations)],'runtime_order')
            password=secrets.token_urlsafe(32);rotation=str(uuid.uuid4());require(password!=self.password,'runtime_entropy_collision')
            self.io.pending('runtime_'+v['phase'],rotation);self.io.rotate(password)
            self.password=password;self.rotations.append(rotation);answer.update(password=password,rotationId=rotation)
        elif op=='publish':
            require(set(v)=={'format','sequence','operation','receipt','checks'} and self.bootstrap_index==len(BOOTSTRAPS) and len(self.rotations)==2 and self.published is None,'publication_order')
            sealed_receipt(v['receipt'],self.scope,self.rotations);require(v['checks']==self.before_checks(),'transport_checks_incomplete')
            version=str(uuid.uuid4());self.io.pending('publish',version);self.published=self.io.publish(self.password,version,v['receipt'])
            require(isinstance(self.published,dict) and set(self.published)=={'password','arn','versionId'} and self.published['password']==self.password and self.published['versionId']==version and self.published['arn']==self.io.runtime_secret_arn,'publication_response_mismatch')
            answer.update(persistedPassword=self.published['password'],secretRef={k:self.published[k] for k in ['arn','versionId']})
        elif op=='result':
            require(set(v)=={'format','sequence','operation','ok','receipt','checks','secretRef'} and v['ok'] is True and self.published is not None,'guest_result_refused')
            sealed_receipt(v['receipt'],self.scope,self.rotations)
            require(v['checks']==self.before_checks()+['exact_persisted_version_fresh_tls_readiness'] and v['secretRef']=={k:self.published[k] for k in ['arn','versionId']},'persisted_readiness_missing')
            self.result={k:v[k] for k in ['ok','receipt','checks','secretRef']};return b''
        else:raise SecretIoError('guest_operation_refused')
        self.io.deadline();return (json.dumps(answer)+'\n').encode()
