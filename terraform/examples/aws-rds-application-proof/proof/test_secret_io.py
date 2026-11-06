import os
import sys
import unittest
from secret_io import run,SecretIoError
class SensitiveIo(unittest.TestCase):
    def test_private_input_has_no_result_repr_or_error_repr(self):
        canary=b'synthetic-not-real-credential'
        result=run([sys.executable,'-c','import sys;v=sys.stdin.buffer.read();sys.stdout.buffer.write(v);sys.stderr.buffer.write(v)'],input_bytes=canary,env={},timeout=5)
        self.assertEqual(result.stdout,canary);self.assertEqual(result.stderr,canary)
        self.assertNotIn(canary.decode(),repr(result))
    def test_output_bound_and_timeout_are_typed(self):
        for code,expected in [('import sys;sys.stdout.write("x"*10000)','sensitive_output_bound'),('import time;time.sleep(30)','sensitive_timeout')]:
            with self.subTest(expected=expected),self.assertRaises(SecretIoError) as error:
                run([sys.executable,'-c',code],env={},timeout=.2,max_output=256)
            self.assertEqual(error.exception.code,expected)
            self.assertNotIn('sys.',str(error.exception))
    def test_closed_stdin_without_consumption_and_nonzero_exit(self):
        result=run([sys.executable,'-c','raise SystemExit(3)'],input_bytes=b'canary',env={},timeout=5)
        self.assertEqual(result.returncode,3)
    def test_timeout_reaps_owned_grandchild(self):
        code='import subprocess,sys,time;subprocess.Popen([sys.executable,"-c","import time;time.sleep(30)"]);time.sleep(30)'
        with self.assertRaises(SecretIoError) as error:run([sys.executable,'-c',code],env={},timeout=.3)
        self.assertEqual(error.exception.code,'sensitive_timeout')
if __name__=='__main__':unittest.main()
