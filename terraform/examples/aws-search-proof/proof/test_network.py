import copy
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch
from contract import native_error
from network import interfaces, network, rules
from test_contract import inputs

def groups(v):
    base={'OwnerId':v['account_id'],'VpcId':v['vpc_id']}
    return [{**base,'GroupId':'sg-client','GroupName':'client','IpPermissions':[]}, {**base,'GroupId':'sg-domain','GroupName':'exclusive-domain','IpPermissions':[{'IpProtocol':'tcp','FromPort':443,'ToPort':443,'UserIdGroupPairs':[{'GroupId':'sg-client','UserId':v['account_id']}]}]}]

class Network(unittest.TestCase):
    def test_only_exact_private_https_peer_ingress(self):
        v=inputs();rules(groups(v),v)
        for variant in ['world','foreign','port','default','missing']:
            data=groups(v);d=data[1]
            if variant=='world':d['IpPermissions'][0]['IpRanges']=[{'CidrIp':'0.0.0.0/0'}]
            if variant=='foreign':d['IpPermissions'][0]['UserIdGroupPairs'][0]['UserId']='222222222222'
            if variant=='port':d['IpPermissions'][0]['FromPort']=80
            if variant=='default':d['GroupName']='default'
            if variant=='missing':d['IpPermissions']=[]
            with self.subTest(variant=variant),self.assertRaises(RuntimeError):rules(data,v)

    def test_partial_eni_pages_and_denial_are_not_empty(self):
        for page in [{},{'NetworkInterfaces':[],'NextToken':'more'}]:
            runner=SimpleNamespace(v=inputs(),aws=lambda *a,**k:SimpleNamespace(stdout=json.dumps(page)))
            with self.assertRaises(RuntimeError):interfaces(runner)

    def test_profile_does_not_gain_common_eni_read_permissions(self):
        r=SimpleNamespace(env={'PIPPEN_SANDBOX_CAPABILITY_CONTEXT':'synthetic'})
        with self.assertRaisesRegex(RuntimeError,'ordinary common-role'):network(r,'network-before')

if __name__ == '__main__': unittest.main()
