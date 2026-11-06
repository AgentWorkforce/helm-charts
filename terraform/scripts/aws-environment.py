#!/usr/bin/env python3
"""Run the AWS data root with an explicit environment/backend and saved-plan binding.

Run this inside pippen sandbox exec for sandbox deployments. This program never
allocates an account, changes IAM guardrails or reads a secret payload.
"""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
STACK = ROOT / "examples" / "aws-environments"
BACKEND_KEYS = {"bucket", "key", "region", "encrypt", "use_lockfile", "expected_bucket_owner", "kms_key_id", "allowed_account_ids"}


class Refused(Exception):
    pass


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def source_digest(root=ROOT):
    h = hashlib.sha256()
    for path in sorted(root.rglob("*")):
        rel = path.relative_to(root)
        if any(p.startswith(".") for p in rel.parts[:-1]) or not path.is_file():
            continue
        if not (path.name.endswith((".tf", ".tfvars", ".tfvars.json")) or path.name in (".terraform.lock.hcl", "aws-environment.py")):
            continue
        h.update(str(rel).encode() + b"\0" + path.read_bytes() + b"\0")
    return h.hexdigest()


def read_inputs(variables_path, backend_path):
    variables = json.loads(variables_path.read_text())
    backend = json.loads(backend_path.read_text())
    if not isinstance(variables, dict) or not isinstance(backend, dict):
        raise Refused("Variable and backend files must be JSON objects")
    account, environment, region = (variables.get(k, "") for k in ("account_id", "environment", "region"))
    if not isinstance(account, str) or not re.fullmatch(r"[0-9]{12}", account):
        raise Refused("Set an exact 12-digit account_id")
    if not isinstance(environment, str) or not re.fullmatch(r"[a-z][a-z0-9]*(?:-[a-z0-9]+)*", environment) or len(environment) > 16:
        raise Refused("Set an explicit environment slug")
    if not isinstance(region, str) or not re.fullmatch(r"[a-z]{2}(?:-[a-z]+)+-[0-9]+", region):
        raise Refused("Set an explicit AWS region")
    if set(backend) - BACKEND_KEYS:
        raise Refused("Backend contains unsupported settings; credentials/profiles belong only in the runner")
    if backend.get("encrypt") is not True or backend.get("use_lockfile") is not True:
        raise Refused("The backend requires encryption and native S3 state locking")
    key = backend.get("key", "")
    suffix = f"/{account}/{region}/{environment}/data.tfstate"
    if not isinstance(key, str) or not key.endswith(suffix) or ".." in key.split("/") or key.startswith("/"):
        raise Refused("Backend key must end in /<account_id>/<region>/<environment>/data.tfstate")
    if not isinstance(backend.get("bucket"), str) or not re.fullmatch(r"[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]", backend["bucket"]):
        raise Refused("Set the approved existing state bucket")
    if not re.fullmatch(r"[0-9]{12}", str(backend.get("expected_bucket_owner", ""))):
        raise Refused("Set the exact expected_bucket_owner for the state bucket")
    return variables, backend


def verify_caller(variables, caller, environ):
    account = variables["account_id"]
    if caller.get("Account") != account:
        raise Refused("AWS caller account does not match the environment")
    pippen = variables.get("pippen")
    lease_keys = ("PIPPEN_SANDBOX_ACCOUNT_ID", "PIPPEN_SANDBOX_SESSION_ID", "PIPPEN_SANDBOX_AGENT_ID")
    if pippen is None and any(key in environ for key in lease_keys):
        raise Refused("Pippen execution requires the declared lease identity; customer defaults are refused")
    if pippen is not None:
        if not isinstance(pippen, dict) or not all(isinstance(pippen.get(k), str) and pippen[k] for k in ("agent", "session_id")):
            raise Refused("Pippen agent/session identity is incomplete")
        expected = f"arn:aws:sts::{account}:assumed-role/agent-session/agent-{pippen['session_id']}"
        if caller.get("Arn") != expected or environ.get("PIPPEN_SANDBOX_ACCOUNT_ID") != account or environ.get("PIPPEN_SANDBOX_SESSION_ID") != pippen["session_id"] or environ.get("PIPPEN_SANDBOX_AGENT_ID") != pippen["agent"]:
            raise Refused("Run under the exact allocated Pippen lease with pippen sandbox exec")
        if not variables.get("name_prefix", "").startswith("pippen-sbx-"):
            raise Refused("Pippen resources require a pippen-sbx- prefix")


def plan_binding(variables_path, backend_path, source_root=ROOT):
    binding = {"variables_sha256": digest(variables_path), "backend_sha256": digest(backend_path), "source_sha256": source_digest(source_root)}
    package = json.loads(variables_path.read_text()).get("lambda_package")
    if package and package.get("filename"):
        import base64
        path = Path(package["filename"])
        if not path.is_absolute():
            path = source_root / "examples" / "aws-environments" / path
        artifact_sha = digest(path)
        if base64.b64encode(bytes.fromhex(artifact_sha)).decode() != package.get("source_code_hash"):
            raise Refused("Local Lambda package does not match its reviewed source_code_hash")
        binding["artifact_sha256"] = artifact_sha
    return binding


def verify_plan(plan, receipt, binding, approved_sha):
    if not plan.is_file() or not receipt.is_file():
        raise Refused("Create and review this environment's saved plan first")
    recorded = json.loads(receipt.read_text())
    actual = digest(plan)
    if approved_sha != actual or recorded.get("plan_sha256") != actual:
        raise Refused("Approval must name the exact saved plan SHA-256")
    if any(recorded.get(k) != v for k, v in binding.items()):
        raise Refused("Environment/backend/source changed since planning; create a new plan")


def private_json(path, value):
    with path.open("w") as f:
        os.chmod(path, 0o600)
        json.dump(value, f, indent=2)
        f.write("\n")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["init", "plan", "show", "apply", "output"])
    parser.add_argument("--variables", required=True, type=Path, help="Private non-secret .tfvars.json file")
    parser.add_argument("--backend", required=True, type=Path, help="Private non-secret S3 backend JSON file")
    parser.add_argument("--approve-plan", help="Exact reviewed plan SHA-256, required for apply")
    parser.add_argument("--run-dir", type=Path, default=ROOT / ".runs")
    args = parser.parse_args(argv)
    os.umask(0o077)
    variables_path, backend_path = args.variables.resolve(), args.backend.resolve()
    variables, _ = read_inputs(variables_path, backend_path)
    tool = os.environ.get("TF_BIN", "terraform")
    if tool not in ("terraform", "tofu"):
        raise Refused("TF_BIN must be terraform or tofu from the approved runner")
    workspace = os.environ.get("TF_WORKSPACE", "default")
    if workspace != "default":
        raise Refused("Use separate backend keys/configuration, not a selected CLI workspace")
    # Do not allow environment-injected Terraform flags/variables to silently
    # change a reviewed target, disable refresh or bypass locking.
    child_env = {k: v for k, v in os.environ.items() if not k.startswith(("TF_CLI_ARGS", "TF_VAR_"))}
    child_env.update(TF_IN_AUTOMATION="1", TF_INPUT="0", AWS_REGION=variables["region"], AWS_DEFAULT_REGION=variables["region"])
    directory = args.run_dir.resolve() / variables["account_id"] / variables["region"] / variables["environment"]
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    child_env["TF_DATA_DIR"] = str(directory / ".terraform")
    prefix = [tool, f"-chdir={STACK}"]

    with (directory / "operation.lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as exc:
            raise Refused("Another operation is active for this environment") from exc
        caller = json.loads(subprocess.check_output(["aws", "sts", "get-caller-identity", "--output", "json"], env=child_env, stderr=subprocess.DEVNULL))
        verify_caller(variables, caller, child_env)
        plan, receipt = directory / "data.tfplan", directory / "plan-receipt.json"
        binding = plan_binding(variables_path, backend_path)
        if args.command == "apply":
            verify_plan(plan, receipt, binding, args.approve_plan)
        elif args.command == "show":
            verify_plan(plan, receipt, binding, digest(plan) if plan.is_file() else None)
        subprocess.run(prefix + ["init", "-reconfigure", "-input=false", "-lockfile=readonly", f"-backend-config={backend_path}"], env=child_env, check=True)
        actual_workspace = subprocess.check_output(prefix + ["workspace", "show"], env=child_env).decode().strip()
        if actual_workspace != "default":
            raise Refused("Cached Terraform CLI workspace is not default; refuse environment aliasing")
        if args.command == "plan":
            # Remove old approval metadata before attempting a replacement plan.
            receipt.unlink(missing_ok=True)
            subprocess.run(prefix + ["plan", "-input=false", f"-var-file={variables_path}", f"-out={plan}"], env=child_env, check=True)
            sha = digest(plan)
            private_json(receipt, {**binding, "plan_sha256": sha, "account_id": variables["account_id"], "environment": variables["environment"]})
            print(f"Saved plan: {plan}\nSHA-256: {sha}\nReview this plan before invoking apply --approve-plan <SHA-256>.")
        elif args.command == "apply":
            subprocess.run(prefix + ["apply", "-input=false", str(plan)], env=child_env, check=True)
            receipt.unlink()  # Every further apply requires a new reviewed plan.
        elif args.command == "show":
            subprocess.run(prefix + ["show", "-no-color", str(plan)], env=child_env, check=True)
        elif args.command == "output":
            output = subprocess.check_output(prefix + ["output", "-json", "verification"], env=child_env)
            value = json.loads(output)
            if value.get("account_id") != variables["account_id"] or value.get("environment") != variables["environment"] or value.get("region") != variables["region"]:
                raise Refused("State outputs belong to another environment")
            private_json(directory / "verification.json", value)
            print(f"Non-secret verification references: {directory / 'verification.json'}")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (Refused, ValueError, OSError, subprocess.SubprocessError) as exc:
        # Do not echo subprocess bodies, credential material or configuration.
        reason = str(exc) if isinstance(exc, Refused) else type(exc).__name__
        print(f"Refused: {reason}", file=sys.stderr)
        sys.exit(1)
