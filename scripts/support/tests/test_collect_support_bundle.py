#!/usr/bin/env python3

import hashlib
import importlib.util
import io
import json
import pathlib
import sys
import tarfile
import tempfile
import unittest
from unittest import mock


SCRIPT = pathlib.Path(__file__).parents[1] / "collect-support-bundle.py"
SPEC = importlib.util.spec_from_file_location("support_bundle", SCRIPT)
assert SPEC and SPEC.loader
support_bundle = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = support_bundle
SPEC.loader.exec_module(support_bundle)


class CommandPolicyTests(unittest.TestCase):
    def test_secret_reads_are_blocked_with_global_flags(self):
        for resource in ("secret", "secrets", "secrets.v1", "secret/example"):
            with self.subTest(resource=resource):
                with self.assertRaisesRegex(
                    support_bundle.CollectionError, "Secret reads"
                ):
                    support_bundle.CommandPolicy.check(
                        [
                            "kubectl",
                            "--context",
                            "test",
                            "--namespace",
                            "relay",
                            "get",
                            resource,
                            "--output",
                            "json",
                        ]
                    )

    def test_option_values_are_not_mistaken_for_verbs(self):
        for command in (
            ["kubectl", "--namespace", "get", "get", "pods", "--output", "json"],
            ["kubectl", "--namespace", "top", "top", "pods", "--no-headers"],
            ["helm", "status", "status", "--namespace", "x", "--output", "json"],
            ["helm", "--namespace", "history", "history", "relay"],
            ["helm", "get", "values", "get", "--namespace", "x", "--all"],
        ):
            with self.subTest(command=command):
                support_bundle.CommandPolicy.check(command)

    def test_every_kubectl_operand_is_checked_for_secrets(self):
        for command in (
            ["kubectl", "--namespace", "x", "get", "pods", "secrets"],
            ["kubectl", "get", "pods", "secret/example", "--output", "json"],
            ["kubectl", "-n", "x", "get", "pods,secrets"],
        ):
            with self.subTest(command=command):
                with self.assertRaisesRegex(
                    support_bundle.CollectionError, "Secret reads"
                ):
                    support_bundle.CommandPolicy.check(command)

    def test_unknown_options_and_extra_operands_are_rejected(self):
        for command in (
            ["kubectl", "--token", "abc", "get", "pods"],
            ["kubectl", "get", "pods", "--raw", "/api/v1/secrets"],
            ["kubectl", "--namespace"],
            ["helm", "status", "relay", "--show-resources"],
            ["helm", "status", "relay", "other"],
            ["helm", "get", "manifest", "relay"],
        ):
            with self.subTest(command=command):
                with self.assertRaises(support_bundle.CollectionError):
                    support_bundle.CommandPolicy.check(command)

    def test_mutating_commands_are_blocked(self):
        for command in (
            ["kubectl", "delete", "pods", "--all"],
            ["kubectl", "apply", "-f", "manifest.yaml"],
            ["helm", "upgrade", "relay", "chart"],
        ):
            with self.subTest(command=command):
                with self.assertRaises(support_bundle.CollectionError):
                    support_bundle.CommandPolicy.check(command)

    def test_password_urls_are_blocked_before_execution(self):
        with self.assertRaisesRegex(
            support_bundle.CollectionError, "password-bearing"
        ):
            support_bundle.CommandPolicy.check(
                [
                    "kubectl",
                    "get",
                    "pods",
                    "--server=https://admin:hunter2@example.test",
                ]
            )

    @mock.patch.object(support_bundle.subprocess, "run")
    def test_allowed_command_uses_no_shell(self, run):
        run.return_value = support_bundle.subprocess.CompletedProcess(
            ["kubectl"], 0, "{}", ""
        )
        support_bundle.CommandRunner(5).run_json(
            ["kubectl", "--namespace", "relay", "get", "pods", "-o", "json"]
        )
        self.assertFalse(run.call_args.kwargs["shell"])


class RedactionTests(unittest.TestCase):
    def test_sensitive_value_changes_do_not_change_fingerprint(self):
        first = {
            "replicas": 2,
            "database": {"password": "first-password", "host": "db.internal"},
            "clientSecret": "first-secret",
        }
        second = {
            "replicas": 2,
            "database": {"password": "second-password", "host": "db.internal"},
            "clientSecret": "second-secret",
        }
        self.assertEqual(
            support_bundle.configuration_fingerprint(first)["sha256"],
            support_bundle.configuration_fingerprint(second)["sha256"],
        )

    def test_safe_value_change_changes_fingerprint(self):
        first = support_bundle.configuration_fingerprint({"replicas": 2})
        second = support_bundle.configuration_fingerprint({"replicas": 3})
        self.assertNotEqual(first["sha256"], second["sha256"])

    def test_scanner_reports_category_but_not_credential(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            (root / "bad.json").write_text(
                '{"password":"do-not-report-this"}\n'
                '{"url":"postgres://alice:also-secret@db.test/app"}\n',
                encoding="utf-8",
            )
            findings = support_bundle.scan_tree(root)
        rendered = json.dumps(findings)
        self.assertIn("credential-assignment", rendered)
        self.assertIn("password-bearing-url", rendered)
        self.assertNotIn("do-not-report-this", rendered)
        self.assertNotIn("also-secret", rendered)


class ArchiveTests(unittest.TestCase):
    def test_archive_entries_have_normalized_ownership_and_checksum(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary) / "staging"
            root.mkdir()
            (root / "manifest.json").write_text("{}\n", encoding="utf-8")
            archive_path = pathlib.Path(temporary) / "bundle.tar.gz"
            checksum_path = support_bundle.create_archive(root, archive_path)

            expected = hashlib.sha256(archive_path.read_bytes()).hexdigest()
            self.assertEqual(
                checksum_path.read_text(encoding="ascii"),
                f"{expected}  bundle.tar.gz\n",
            )
            with tarfile.open(archive_path, "r:gz") as archive:
                for member in archive.getmembers():
                    self.assertEqual(member.uid, 0)
                    self.assertEqual(member.gid, 0)
                    self.assertEqual(member.uname, "root")
                    self.assertEqual(member.gname, "root")
                    self.assertEqual(member.mtime, 0)


class MockedCollectionTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.options = support_bundle.Options(
            namespace="relay",
            release="agent-relay",
            context="test",
            selector="app.kubernetes.io/instance=agent-relay",
            output_dir=pathlib.Path(self.temporary.name),
            health_urls=[],
            health_path="/health",
            timeout=5,
            skip_network=True,
            release_evidence=None,
            max_backup_age_hours=24,
        )

    def test_curates_mocked_cluster_data_without_raw_secrets(self):
        runner = mock.create_autospec(support_bundle.CommandRunner, instance=True)

        def json_result(argv):
            # Every command the collector builds must pass the policy.
            support_bundle.CommandPolicy.check(argv)
            if "status" in argv:
                return {
                    "name": "agent-relay",
                    "version": 7,
                    "info": {"status": "deployed"},
                    "chart": {
                        "metadata": {
                            "name": "agent-relay",
                            "version": "1.2.3",
                            "appVersion": "4.5.6",
                        }
                    },
                }
            if "values" in argv:
                return {
                    "replicas": 2,
                    "database": {
                        "host": "db.internal",
                        "password": "must-not-appear",
                    },
                }
            if "deployments.apps,statefulsets.apps,daemonsets.apps" in argv:
                return {
                    "items": [
                        {
                            "kind": "Deployment",
                            "metadata": {"name": "api", "generation": 2},
                            "spec": {
                                "replicas": 1,
                                "template": {
                                    "spec": {
                                        "containers": [
                                            {
                                                "name": "api",
                                                "image": "registry.test/api:4.5.6",
                                                "env": [
                                                    {
                                                        "name": "PASSWORD",
                                                        "value": "inline-secret",
                                                    }
                                                ],
                                            }
                                        ]
                                    }
                                },
                            },
                            "status": {
                                "observedGeneration": 2,
                                "readyReplicas": 1,
                                "availableReplicas": 1,
                                "updatedReplicas": 1,
                            },
                        }
                    ]
                }
            if "pods" in argv:
                return {"items": []}
            if "jobs.batch" in argv:
                return {
                    "items": [
                        {
                            "metadata": {
                                "name": "schema-migrate",
                                "labels": {"job-type": "migration"},
                            },
                            "status": {
                                "succeeded": 1,
                                "conditions": [
                                    {"type": "Complete", "status": "True"}
                                ],
                            },
                        }
                    ]
                }
            if "ingresses.networking.k8s.io" in argv:
                return {"items": []}
            if "resourcequotas" in argv:
                return {"items": []}
            if "history" in argv:
                return [
                    {
                        "revision": 7,
                        "status": "deployed",
                        "chart": "agent-relay-1.2.3",
                        "description": "password=must-not-appear",
                    }
                ]
            raise AssertionError(argv)

        runner.run_json.side_effect = json_result

        def text_result(argv):
            support_bundle.CommandPolicy.check(argv)
            return ""

        runner.run_text.side_effect = text_result
        documents, manifest = support_bundle.collect(self.options, runner)
        rendered = json.dumps({"documents": documents, "manifest": manifest})
        self.assertNotIn("must-not-appear", rendered)
        self.assertNotIn("inline-secret", rendered)
        self.assertEqual(documents["collection-errors.json"]["errors"], [])
        self.assertEqual(documents["versions.json"]["appVersion"], "4.5.6")
        self.assertFalse(
            documents["migration-ledger-status.json"]["credentialsRead"]
        )
        self.assertFalse(
            documents["migration-ledger-status.json"]["databaseRowsRead"]
        )

    def test_manifest_reports_helm_release_storage_secret_reads(self):
        runner = mock.create_autospec(support_bundle.CommandRunner, instance=True)
        runner.run_json.side_effect = support_bundle.CollectionError("offline")
        runner.run_text.return_value = ""
        for driver, expected in (("", True), ("secret", True), ("configmap", False)):
            with self.subTest(driver=driver):
                with mock.patch.dict(support_bundle.os.environ, {"HELM_DRIVER": driver}):
                    _, manifest = support_bundle.collect(self.options, runner)
                self.assertIs(manifest["secretResourcesRead"], expected)
                self.assertEqual(
                    manifest["secretResourcesReadBy"],
                    ["helm-release-storage"] if expected else [],
                )
                self.assertFalse(manifest["kubernetesSecretsCollected"])
                self.assertFalse(manifest["secretPayloadsIncluded"])


if __name__ == "__main__":
    unittest.main()
