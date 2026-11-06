import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("aws_environment", Path(__file__).with_name("aws-environment.py"))
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class EnvironmentBoundaryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.variables = self.root / "dev.tfvars.json"
        self.backend = self.root / "dev.backend.json"
        self.variables.write_text(json.dumps({"account_id": "111111111111", "environment": "dev", "region": "us-west-2"}))
        self.config = {"bucket": "company-terraform-state", "key": "agent-relay/111111111111/us-west-2/dev/data.tfstate", "region": "us-west-2", "encrypt": True, "use_lockfile": True, "expected_bucket_owner": "111111111111"}
        self.write_backend()

    def write_backend(self):
        self.backend.write_text(json.dumps(self.config))

    def test_environment_pair_is_accepted(self):
        variables, backend = runner.read_inputs(self.variables, self.backend)
        self.assertEqual(variables["environment"], "dev")
        self.assertIn("/dev/", backend["key"])

    def test_production_backend_cannot_be_used_for_dev(self):
        self.config["key"] = self.config["key"].replace("/dev/", "/prod/")
        self.write_backend()
        with self.assertRaises(runner.Refused):
            runner.read_inputs(self.variables, self.backend)

    def test_other_account_backend_cannot_be_used(self):
        self.config["key"] = self.config["key"].replace("111111111111", "222222222222")
        self.write_backend()
        with self.assertRaises(runner.Refused):
            runner.read_inputs(self.variables, self.backend)

    def test_other_region_backend_cannot_be_used(self):
        self.config["key"] = self.config["key"].replace("/us-west-2/", "/us-east-1/")
        self.write_backend()
        with self.assertRaises(runner.Refused):
            runner.read_inputs(self.variables, self.backend)

    def test_backend_cannot_smuggle_credentials_or_a_profile(self):
        for key in ("access_key", "secret_key", "profile", "assume_role"):
            with self.subTest(key=key):
                self.config[key] = "not-a-credential"
                self.write_backend()
                with self.assertRaises(runner.Refused):
                    runner.read_inputs(self.variables, self.backend)
                del self.config[key]

    def test_locking_and_encryption_cannot_be_disabled(self):
        for key in ("encrypt", "use_lockfile"):
            self.config[key] = False
            self.write_backend()
            with self.assertRaises(runner.Refused):
                runner.read_inputs(self.variables, self.backend)
            self.config[key] = True

    def test_wrong_caller_account_is_refused(self):
        with self.assertRaises(runner.Refused):
            runner.verify_caller({"account_id": "111111111111"}, {"Account": "222222222222"}, {})

    def test_pippen_lease_cannot_be_substituted(self):
        variables = {"account_id": "111111111111", "name_prefix": "pippen-sbx-ar", "pippen": {"agent": "aws-proof", "session_id": "expected"}}
        caller = {"Account": "111111111111", "Arn": "arn:aws:sts::111111111111:assumed-role/agent-session/agent-expected"}
        environ = {"PIPPEN_SANDBOX_ACCOUNT_ID": "111111111111", "PIPPEN_SANDBOX_SESSION_ID": "expected", "PIPPEN_SANDBOX_AGENT_ID": "aws-proof"}
        runner.verify_caller(variables, caller, environ)
        environ["PIPPEN_SANDBOX_SESSION_ID"] = "other"
        with self.assertRaises(runner.Refused):
            runner.verify_caller(variables, caller, environ)

    def test_pippen_execution_cannot_omit_lease_configuration(self):
        variables = {"account_id": "111111111111"}
        caller = {"Account": "111111111111", "Arn": "arn:aws:sts::111111111111:assumed-role/agent-session/agent-expected"}
        for key in ("PIPPEN_SANDBOX_ACCOUNT_ID", "PIPPEN_SANDBOX_SESSION_ID", "PIPPEN_SANDBOX_AGENT_ID"):
            with self.subTest(key=key), self.assertRaises(runner.Refused):
                runner.verify_caller(variables, caller, {key: "present"})
        runner.verify_caller(variables, {"Account": "111111111111", "Arn": "arn:aws:sts::111111111111:assumed-role/customer-deployer/session"}, {})

    def test_apply_requires_exact_plan_and_unchanged_inputs(self):
        plan, receipt = self.root / "plan", self.root / "receipt.json"
        plan.write_bytes(b"synthetic plan")
        binding = runner.plan_binding(self.variables, self.backend, self.root)
        sha = runner.digest(plan)
        receipt.write_text(json.dumps({**binding, "plan_sha256": sha}))
        runner.verify_plan(plan, receipt, binding, sha)
        with self.assertRaises(runner.Refused):
            runner.verify_plan(plan, receipt, binding, "wrong-plan")
        self.variables.write_text(self.variables.read_text() + "\n")
        with self.assertRaises(runner.Refused):
            runner.verify_plan(plan, receipt, runner.plan_binding(self.variables, self.backend, self.root), sha)

    def test_changed_module_invalidates_saved_plan(self):
        source = self.root / "main.tf"
        source.write_text('resource "terraform_data" "test" {}')
        before = runner.source_digest(self.root)
        source.write_text('resource "terraform_data" "different" {}')
        self.assertNotEqual(before, runner.source_digest(self.root))

    def test_private_receipt_permissions(self):
        path = self.root / "receipt.json"
        runner.private_json(path, {"environment": "dev"})
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)

    def test_dependency_lock_and_runner_changes_invalidate_plan(self):
        for filename in (".terraform.lock.hcl", "aws-environment.py", "terraform.tfvars.json"):
            with self.subTest(filename=filename):
                path = self.root / filename
                path.write_text("before")
                before = runner.source_digest(self.root)
                path.write_text("after")
                self.assertNotEqual(before, runner.source_digest(self.root))

    def test_local_lambda_bytes_must_match_package_hash(self):
        import base64
        artifact = self.root / "pipeline.zip"
        artifact.write_bytes(b"reviewed artifact")
        values = json.loads(self.variables.read_text())
        values["lambda_package"] = {"filename": str(artifact), "source_code_hash": base64.b64encode(bytes.fromhex(runner.digest(artifact))).decode()}
        self.variables.write_text(json.dumps(values))
        runner.plan_binding(self.variables, self.backend, self.root)
        artifact.write_bytes(b"different artifact")
        with self.assertRaises(runner.Refused):
            runner.plan_binding(self.variables, self.backend, self.root)

    def test_cached_workspace_stops_before_plan_or_apply(self):
        replies = [json.dumps({"Account": "111111111111"}).encode(), b"prod\n"]
        with patch.dict(runner.os.environ, {"TF_BIN": "terraform", "TF_WORKSPACE": "default"}), patch.object(runner.subprocess, "check_output", side_effect=replies), patch.object(runner.subprocess, "run") as run:
            with self.assertRaises(runner.Refused):
                runner.main(["plan", "--variables", str(self.variables), "--backend", str(self.backend), "--run-dir", str(self.root / "runs")])
            self.assertEqual(run.call_count, 1)
            self.assertEqual(run.call_args.args[0][2], "init")

    def test_injected_flags_and_variables_are_removed(self):
        replies = [json.dumps({"Account": "111111111111"}).encode(), b"default\n"]
        with patch.dict(runner.os.environ, {"TF_BIN": "terraform", "TF_WORKSPACE": "default", "TF_CLI_ARGS_init": "-backend=false", "TF_VAR_account_id": "222222222222"}), patch.object(runner.subprocess, "check_output", side_effect=replies), patch.object(runner.subprocess, "run") as run:
            runner.main(["init", "--variables", str(self.variables), "--backend", str(self.backend), "--run-dir", str(self.root / "runs")])
            environment = run.call_args.kwargs["env"]
            self.assertNotIn("TF_CLI_ARGS_init", environment)
            self.assertNotIn("TF_VAR_account_id", environment)
            self.assertIn("-lockfile=readonly", run.call_args.args[0])


if __name__ == "__main__":
    unittest.main()
