import unittest
import subprocess
from unittest.mock import patch
import retirement as r

class RetirementTests(unittest.TestCase):
    def test_nested_credential_error_is_not_target_absence(self):
        result=subprocess.CompletedProcess([],1,'','An error occurred (NoSuchEntity) when calling the AssumeRole operation')
        with patch.object(r.subprocess,'run',return_value=result):
            with self.assertRaises(RuntimeError):r.request({'region':'us-west-2'},'iam','get-role','--role-name','synthetic')
    def test_specific_missing_only(self):
        for error,want in [('NoSuchBucket',True),('AccessDenied',False),('RequestTimeout',False)]:
            with patch.object(r,'request',return_value=(None,error)):
                self.assertEqual(r.absent({},'s3api','list-object-versions',[],'NoSuchBucket'),want)
        for value in [{},{'IsTruncated':False}]:
            with patch.object(r,'request',return_value=(value,None)):
                self.assertFalse(r.absent({},'s3api','list-object-versions',[],'NoSuchBucket'))

if __name__=='__main__':unittest.main()
