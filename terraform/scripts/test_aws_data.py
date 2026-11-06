import importlib.util
import io
from pathlib import Path
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("aws_data", Path(__file__).with_name("verify-aws-data.py"))
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)


def fixture():
    return {
        "account_id": "111111111111", "environment": "dev", "region": "us-west-2",
        "storage": {"prefix": "proofs/dev/", "bucket": "agent-relay-dev-111111111111-us-west-2-sessions", "role_arn": "arn:aws:iam::111111111111:role/storage"},
        "postgres": {"host": "database.abc.us-west-2.rds.amazonaws.com", "secret_arn": "arn:aws:secretsmanager:us-west-2:111111111111:secret:db", "resource_arn": "arn:aws:rds:us-west-2:111111111111:db:database"},
        "search": {"url": "https://vpc-test.us-west-2.es.amazonaws.com", "domain_arn": "arn:aws:es:us-west-2:111111111111:domain/agent-relay-dev-search", "domain_name": "agent-relay-dev-search", "index_prefix": "agent-relay-dev-", "master_role_arn": "arn:aws:iam::111111111111:role/admin", "indexer_role_arn": "arn:aws:iam::111111111111:role/writer", "reader_role_arn": "arn:aws:iam::111111111111:role/reader", "lambda_role_arn": "arn:aws:iam::111111111111:role/pipeline"},
        "pipeline": {"function_arn": "arn:aws:lambda:us-west-2:111111111111:function:proof", "image_uri": None},
    }


class DataProofRefusalTests(unittest.TestCase):
    def test_target_metadata_must_match_confirmed_environment(self):
        probe.validate(fixture(), "111111111111", "dev", "a" * 32)
        for account, environment in [("222222222222", "dev"), ("111111111111", "prod")]:
            with self.assertRaises(probe.Failed):
                probe.validate(fixture(), account, environment, "a" * 32)

    def test_search_cannot_redirect_signed_requests_elsewhere(self):
        for url in ("http://vpc-test.us-west-2.es.amazonaws.com", "https://attacker.example", "https://vpc-test.us-west-2.es.amazonaws.com@attacker.example", "https://vpc-test.us-west-2.es.amazonaws.com/path", "https://vpc-test.us-west-2.es.amazonaws.com?redirect=1"):
            value = fixture()
            value["search"]["url"] = url
            with self.subTest(url=url), self.assertRaises(probe.Failed):
                probe.validate(value, "111111111111", "dev", "a" * 32)

    def test_secret_reference_cannot_select_another_account(self):
        value = fixture()
        value["postgres"]["secret_arn"] = value["postgres"]["secret_arn"].replace("111111111111", "222222222222")
        with self.assertRaises(probe.Failed):
            probe.validate(value, "111111111111", "dev", "a" * 32)

    def test_runtime_role_cannot_be_search_administrator(self):
        for section, key in (("search", "reader_role_arn"), ("search", "lambda_role_arn"), ("storage", "role_arn")):
            value = fixture()
            value["search"]["master_role_arn"] = value[section][key]
            with self.subTest(role=key), self.assertRaises(probe.Failed):
                probe.validate(value, "111111111111", "dev", "a" * 32)

    def test_bulk_http_success_is_not_a_write_refusal(self):
        self.assertTrue(probe.bulk_is_refused(403, {}))
        self.assertTrue(probe.bulk_is_refused(200, {"errors": True, "items": [{"index": {"status": 403}}]}))
        for body in ({}, {"errors": False, "items": [{"index": {"status": 201}}]}, {"errors": True, "items": []}, {"errors": True, "items": [{"index": {"status": 403}}, {"index": {"status": 201}}]}):
            self.assertFalse(probe.bulk_is_refused(200, body))

    def test_signed_http_redirects_are_not_followed(self):
        self.assertIsNone(probe.NoRedirect().redirect_request(None, None, 302, "Found", {}, "https://attacker.example"))

    def test_http_success_requires_real_service_acknowledgement(self):
        for check, args in ((probe.index_ack, (200, {})), (probe.security_ack, (200, {"status": "ERROR"})), (probe.document_ack, (201, {"result": "created", "_index": "wrong", "_id": "accepted", "_shards": {"failed": 0}}, "expected", "accepted"))):
            with self.subTest(check=check.__name__), self.assertRaises(probe.Failed):
                check(*args)
        probe.index_ack(200, {"acknowledged": True})
        probe.security_ack(201, {"status": "CREATED"})
        probe.document_ack(201, {"result": "created", "_index": "expected", "_id": "accepted", "_shards": {"failed": 0}}, "expected", "accepted")

    def test_iam_role_path_and_sts_identity_must_match_account_and_role(self):
        expected = "arn:aws:iam::111111111111:role/pippen/workload/reader"
        self.assertTrue(probe.role_matches("arn:aws:sts::111111111111:assumed-role/reader/session", expected))
        self.assertFalse(probe.role_matches("arn:aws:sts::222222222222:assumed-role/reader/session", expected))
        self.assertFalse(probe.role_matches("arn:aws:sts::111111111111:assumed-role/admin/session", expected))

    def test_missing_rds_ca_does_not_read_credentials(self):
        class NoCalls:
            def client(self, name):
                raise AssertionError("Missing CA must fail before any AWS request")
        with self.assertRaises(probe.Failed):
            probe.postgres(NoCalls(), fixture(), None)

    def test_lambda_artifact_mismatch_prevents_invocation(self):
        class Lambda:
            def get_function(self, **kwargs):
                return {"Configuration": {"FunctionArn": fixture()["pipeline"]["function_arn"], "State": "Active", "LastUpdateStatus": "Successful", "Architectures": ["arm64"], "VpcConfig": {"SubnetIds": ["subnet-a"], "SecurityGroupIds": ["sg-a"]}, "CodeSha256": "different", "Runtime": "nodejs24.x"}}
            def invoke(self, **kwargs):
                raise AssertionError("Mismatched code cannot be invoked")
        class Session:
            def client(self, name):
                return Lambda()
        with self.assertRaises(probe.Failed):
            probe.lambda_smoke(Session(), fixture(), "reviewed-code-sha")

    def test_lambda_function_error_is_failure_even_with_http_200(self):
        class Lambda:
            def get_function(self, **kwargs):
                return {"Configuration": {"FunctionArn": fixture()["pipeline"]["function_arn"], "State": "Active", "LastUpdateStatus": "Successful", "Architectures": ["arm64"], "VpcConfig": {"SubnetIds": ["subnet-a"], "SecurityGroupIds": ["sg-a"]}, "CodeSha256": "reviewed", "Runtime": "nodejs24.x", "Timeout": 300}}
            def invoke(self, **kwargs):
                return {"StatusCode": 200, "FunctionError": "Unhandled", "Payload": io.BytesIO(b'{"ok":true}')}
        class Session:
            def client(self, name, **kwargs):
                return Lambda()
        # Unit tests run without boto3/botocore installed in CI. The Config
        # constructor is just a container for the explicit timeout/retry policy.
        import types
        config_module = types.ModuleType("botocore.config")
        config_module.Config = lambda **kwargs: kwargs
        with patch.dict("sys.modules", {"botocore.config": config_module}), self.assertRaises(probe.Failed):
            probe.lambda_smoke(Session(), fixture(), "reviewed")


if __name__ == "__main__":
    unittest.main()
