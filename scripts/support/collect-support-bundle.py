#!/usr/bin/env python3
"""Create a read-only, redacted support bundle for an Agent Relay release."""

from __future__ import annotations

import argparse
import datetime as dt
import gzip
import hashlib
import http.client
import ipaddress
import json
import os
import pathlib
import re
import socket
import ssl
import subprocess
import sys
import tarfile
import tempfile
from dataclasses import dataclass
from typing import Any, Iterable
from urllib.parse import urlsplit

COLLECTOR_VERSION = "1.0.0"
SENSITIVE_KEY_SUFFIXES = {
    "authorization",
    "bearer",
    "clientsecret",
    "credential",
    "credentials",
    "password",
    "passwd",
    "pwd",
    "privatekey",
    "secret",
    "secrets",
    "token",
    "apikey",
    "accesskey",
    "cookie",
    "dsn",
    "databaseurl",
    "connectionstring",
    "url",
    "uri",
}
SENSITIVE_TEXT = re.compile(
    r"-----BEGIN [A-Z ]*PRIVATE KEY-----|"
    r"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b|"
    r"\b(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})\b|"
    r"\bBearer\s+[A-Za-z0-9._~+/=-]{8,}",
    re.IGNORECASE,
)
ASSIGNMENT_CREDENTIAL = re.compile(
    r"""(?ix)
    ["']?(?:password|passwd|pwd|client[_-]?secret|api[_-]?key|
    access[_-]?key|authorization|token)["']?
    \s*[:=]\s*
    ["']?(?!null\b|none\b|redacted\b|excluded\b)[^\s"',}{]{4,}
    """
)
MIGRATION_RE = re.compile(r"(migrat|schema|database[-_]?setup|db[-_]?setup)", re.I)
BACKUP_RE = re.compile(r"(backup|snapshot)", re.I)
CORRELATION_HEADERS = (
    "x-request-id",
    "x-correlation-id",
    "traceparent",
    "x-cloud-trace-context",
)


class CollectionError(RuntimeError):
    pass


def utc_now() -> dt.datetime:
    return dt.datetime.now(dt.timezone.utc)


def isoformat(value: dt.datetime) -> str:
    return value.astimezone(dt.timezone.utc).isoformat().replace("+00:00", "Z")


def password_bearing_url(value: str) -> bool:
    for match in re.finditer(r"[A-Za-z][A-Za-z0-9+.-]*://[^\s\"'<>]+", value):
        try:
            parsed = urlsplit(match.group(0).rstrip(".,);]"))
        except ValueError:
            return True
        if parsed.username is not None or parsed.password is not None:
            return True
    return False


def sensitive_key(value: str) -> bool:
    normalized = re.sub(r"[^a-z0-9]", "", value.lower())
    return any(normalized.endswith(suffix) for suffix in SENSITIVE_KEY_SUFFIXES)


def validate_url(value: str, *, allow_query: bool = False) -> str:
    if password_bearing_url(value):
        raise CollectionError("password-bearing URLs are forbidden")
    try:
        parsed = urlsplit(value)
        port = parsed.port
    except ValueError as error:
        raise CollectionError("invalid health URL") from error
    if parsed.scheme not in {"http", "https"} or not parsed.hostname:
        raise CollectionError("health URLs must use HTTP(S) and include a host")
    if parsed.fragment or (parsed.query and not allow_query):
        raise CollectionError("health URLs must not include a query or fragment")
    if port is not None and not 1 <= port <= 65535:
        raise CollectionError("health URL port is outside the valid range")
    return value


class CommandPolicy:
    """The only gateway for external commands used by this collector."""

    KUBECTL_READ_VERBS = {"get", "top"}
    HELM_READ_FORMS = {("status",), ("history",), ("get", "values")}

    # Options are parsed positionally: anything not listed here is rejected,
    # so an option value can never be mistaken for a verb or resource.
    KUBECTL_GLOBAL_VALUE_OPTIONS = {
        "--context", "--namespace", "-n", "--kubeconfig", "--cluster",
        "--user", "--server", "-s", "--request-timeout", "--as",
        "--as-group", "--as-uid", "--cache-dir", "--certificate-authority",
        "--client-certificate", "--client-key", "--tls-server-name",
    }
    KUBECTL_GLOBAL_FLAGS = {"--insecure-skip-tls-verify", "--match-server-version"}
    KUBECTL_VERB_VALUE_OPTIONS = {
        "--selector", "-l", "--output", "-o", "--field-selector",
        "--sort-by", "--chunk-size", "--label-columns", "-L",
    }
    KUBECTL_VERB_FLAGS = {"--no-headers", "--show-labels", "--ignore-not-found"}
    HELM_GLOBAL_VALUE_OPTIONS = {
        "--kube-context", "--namespace", "-n", "--kubeconfig",
        "--kube-apiserver", "--kube-as-user", "--kube-as-group",
        "--kube-ca-file", "--kube-tls-server-name", "--registry-config",
        "--repository-cache", "--repository-config", "--burst-limit", "--qps",
    }
    HELM_GLOBAL_FLAGS = {"--debug"}
    HELM_COMMAND_VALUE_OPTIONS = {"--output", "-o", "--revision", "--max"}
    HELM_COMMAND_FLAGS = {"--all", "-a"}

    @staticmethod
    def _resource_is_secret(resource: str) -> bool:
        for part in resource.lower().split(","):
            part = part.split("/", 1)[0]
            base = part.split(".", 1)[0]
            if base in {"secret", "secrets"}:
                return True
        return False

    @staticmethod
    def _positionals(
        args: list[str],
        value_options: set[str],
        flags: set[str],
    ) -> list[str]:
        """Return positional words, rejecting any option that is not allowed."""
        positionals: list[str] = []
        index = 0
        while index < len(args):
            argument = args[index]
            if argument == "--":
                raise CollectionError("argument terminators are not allowed")
            if argument.startswith("-") and argument != "-":
                name = argument.split("=", 1)[0]
                if name in value_options:
                    if "=" not in argument:
                        if index + 1 >= len(args):
                            raise CollectionError(f"option {name} requires a value")
                        index += 1
                elif name in flags:
                    pass
                else:
                    raise CollectionError(f"option is not on the read-only allowlist: {name}")
            else:
                positionals.append(argument)
            index += 1
        return positionals

    @classmethod
    def check(cls, argv: Iterable[str]) -> None:
        args = list(argv)
        if not args:
            raise CollectionError("empty external command")
        for argument in args:
            if password_bearing_url(argument):
                raise CollectionError("password-bearing URLs are forbidden")

        executable = pathlib.Path(args[0]).name
        if executable == "kubectl":
            positionals = cls._positionals(
                args[1:],
                cls.KUBECTL_GLOBAL_VALUE_OPTIONS | cls.KUBECTL_VERB_VALUE_OPTIONS,
                cls.KUBECTL_GLOBAL_FLAGS | cls.KUBECTL_VERB_FLAGS,
            )
            if not positionals or positionals[0] not in cls.KUBECTL_READ_VERBS:
                raise CollectionError("kubectl command is not on the read-only allowlist")
            verb, operands = positionals[0], positionals[1:]
            if not operands:
                raise CollectionError("kubectl resource is missing")
            # Every operand is checked: a later operand may be "type/name"
            # or a further resource list.
            if any(cls._resource_is_secret(operand) for operand in operands):
                raise CollectionError("Kubernetes Secret reads are centrally blocked")
            if verb == "top" and operands[0] not in {"pod", "pods"}:
                raise CollectionError("only kubectl top pods is allowed")
        elif executable == "helm":
            positionals = cls._positionals(
                args[1:],
                cls.HELM_GLOBAL_VALUE_OPTIONS | cls.HELM_COMMAND_VALUE_OPTIONS,
                cls.HELM_GLOBAL_FLAGS | cls.HELM_COMMAND_FLAGS,
            )
            if positionals[:1] == ["get"]:
                form, operands = tuple(positionals[:2]), positionals[2:]
            else:
                form, operands = tuple(positionals[:1]), positionals[1:]
            if form not in cls.HELM_READ_FORMS or len(operands) != 1:
                raise CollectionError("Helm command is not on the read-only allowlist")
        else:
            raise CollectionError(f"external command is not allowed: {executable}")


class CommandRunner:
    def __init__(self, timeout: int):
        self.timeout = timeout

    def run(self, argv: list[str]) -> subprocess.CompletedProcess[str]:
        CommandPolicy.check(argv)
        return subprocess.run(
            argv,
            check=False,
            capture_output=True,
            text=True,
            timeout=self.timeout,
            shell=False,
            env={**os.environ, "HELM_DRIVER": helm_driver()},
        )

    def run_json(self, argv: list[str]) -> Any:
        result = self.run(argv)
        if result.returncode:
            raise CollectionError("read-only command failed")
        try:
            return json.loads(result.stdout)
        except json.JSONDecodeError as error:
            raise CollectionError("read-only command returned invalid JSON") from error

    def run_text(self, argv: list[str]) -> str:
        result = self.run(argv)
        if result.returncode:
            raise CollectionError("read-only command failed")
        return result.stdout


def helm_driver() -> str:
    return os.environ.get("HELM_DRIVER") or "secret"


def helm_storage_reads_secrets(driver: str) -> bool:
    """Whether Helm reads release records from Kubernetes Secrets.

    helm status/get values/history load the release record, which with the
    default driver is a sh.helm.release.v1 Secret holding the rendered
    manifest and values. The collector keeps only curated fields and a
    redacted fingerprint, but the Secret itself is read and the collector's
    identity needs get/list on Secrets in the release namespace.
    """
    return driver.lower() in {"secret", "secrets"}


@dataclass
class Options:
    namespace: str
    release: str
    context: str | None
    selector: str
    output_dir: pathlib.Path
    health_urls: list[str]
    health_path: str
    timeout: int
    skip_network: bool
    release_evidence: pathlib.Path | None
    max_backup_age_hours: int


def kubectl_base(options: Options) -> list[str]:
    command = ["kubectl"]
    if options.context:
        command += ["--context", options.context]
    command += ["--namespace", options.namespace]
    return command


def helm_base(options: Options) -> list[str]:
    command = ["helm"]
    if options.context:
        command += ["--kube-context", options.context]
    return command


def safe_leaf(value: Any, path: tuple[str, ...], counts: dict[str, int]) -> Any:
    if path and sensitive_key(path[-1]):
        counts["excluded"] += count_leaves(value)
        return None
    if isinstance(value, dict):
        output = {}
        for key in sorted(value):
            rendered = safe_leaf(value[key], path + (str(key),), counts)
            if rendered is not None:
                output[str(key)] = rendered
        return output
    if isinstance(value, list):
        output = []
        for item in value:
            rendered = safe_leaf(item, path + ("[]",), counts)
            if rendered is not None:
                output.append(rendered)
        return output
    if isinstance(value, str) and (
        password_bearing_url(value) or SENSITIVE_TEXT.search(value)
    ):
        counts["excluded"] += 1
        return None
    counts["included"] += 1
    return value


def count_leaves(value: Any) -> int:
    if isinstance(value, dict):
        return sum(count_leaves(item) for item in value.values()) or 1
    if isinstance(value, list):
        return sum(count_leaves(item) for item in value) or 1
    return 1


def configuration_fingerprint(values: Any) -> dict[str, Any]:
    counts = {"included": 0, "excluded": 0}
    sanitized = safe_leaf(values, (), counts)
    canonical = json.dumps(
        sanitized, sort_keys=True, separators=(",", ":"), ensure_ascii=True
    ).encode()
    return {
        "algorithm": "sha256",
        "sha256": hashlib.sha256(canonical).hexdigest(),
        "includedLeafCount": counts["included"],
        "excludedSensitiveLeafCount": counts["excluded"],
        "rawValuesIncluded": False,
    }


def image_version(image: str) -> dict[str, str]:
    digest = hashlib.sha256(image.encode()).hexdigest()
    version = "unversioned"
    if "@" in image:
        version = image.rsplit("@", 1)[1]
    else:
        final = image.rsplit("/", 1)[-1]
        if ":" in final:
            version = final.rsplit(":", 1)[1]
    return {"version": version, "referenceSha256": digest}


def workload_status(item: dict[str, Any]) -> dict[str, Any]:
    metadata = item.get("metadata", {})
    spec = item.get("spec", {})
    status = item.get("status", {})
    template_spec = spec.get("template", {}).get("spec", {})
    images = []
    for container_type in ("initContainers", "containers"):
        for container in template_spec.get(container_type, []) or []:
            images.append(
                {
                    "container": container.get("name", ""),
                    "type": container_type,
                    **image_version(str(container.get("image", ""))),
                }
            )
    return {
        "kind": item.get("kind", ""),
        "name": metadata.get("name", ""),
        "generation": metadata.get("generation"),
        "observedGeneration": status.get("observedGeneration"),
        "desiredReplicas": spec.get("replicas"),
        "readyReplicas": status.get(
            "readyReplicas", status.get("numberReady", 0)
        ),
        "availableReplicas": status.get("availableReplicas"),
        "updatedReplicas": status.get(
            "updatedReplicas", status.get("updatedNumberScheduled")
        ),
        "unavailableReplicas": status.get(
            "unavailableReplicas", status.get("numberUnavailable")
        ),
        "images": images,
    }


def pod_status(item: dict[str, Any]) -> dict[str, Any]:
    metadata = item.get("metadata", {})
    spec = item.get("spec", {})
    status = item.get("status", {})
    containers = []
    for current in status.get("containerStatuses", []) or []:
        waiting = current.get("state", {}).get("waiting", {})
        terminated = current.get("state", {}).get("terminated", {})
        containers.append(
            {
                "name": current.get("name", ""),
                "ready": bool(current.get("ready")),
                "restartCount": current.get("restartCount", 0),
                "waitingReason": waiting.get("reason"),
                "terminatedReason": terminated.get("reason"),
                "terminatedExitCode": terminated.get("exitCode"),
            }
        )
    resources = []
    for container in spec.get("containers", []) or []:
        resource_spec = container.get("resources", {})
        resources.append(
            {
                "container": container.get("name", ""),
                "requests": resource_spec.get("requests", {}),
                "limits": resource_spec.get("limits", {}),
            }
        )
    return {
        "name": metadata.get("name", ""),
        "phase": status.get("phase", ""),
        "startTime": status.get("startTime"),
        "deleting": metadata.get("deletionTimestamp") is not None,
        "qosClass": status.get("qosClass"),
        "conditions": [
            {
                "type": condition.get("type"),
                "status": condition.get("status"),
                "reason": condition.get("reason"),
            }
            for condition in status.get("conditions", []) or []
        ],
        "containers": containers,
        "resources": resources,
    }


def job_status(item: dict[str, Any]) -> dict[str, Any]:
    metadata = item.get("metadata", {})
    status = item.get("status", {})
    conditions = {
        condition.get("type"): condition.get("status")
        for condition in status.get("conditions", []) or []
    }
    return {
        "name": metadata.get("name", ""),
        "startTime": status.get("startTime"),
        "completionTime": status.get("completionTime"),
        "active": status.get("active", 0),
        "succeeded": status.get("succeeded", 0),
        "failed": status.get("failed", 0),
        "completeCondition": conditions.get("Complete"),
        "failedCondition": conditions.get("Failed"),
    }


def job_search_text(item: dict[str, Any]) -> str:
    metadata = item.get("metadata", {})
    labels = metadata.get("labels", {})
    return " ".join(
        str(value)
        for value in (
            metadata.get("name", ""),
            labels.get("app.kubernetes.io/component", ""),
            labels.get("app.kubernetes.io/name", ""),
            labels.get("job-type", ""),
        )
    )


def parse_timestamp(value: Any) -> dt.datetime | None:
    if not isinstance(value, str):
        return None
    try:
        parsed = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
        if parsed.tzinfo is None:
            return None
        return parsed.astimezone(dt.timezone.utc)
    except ValueError:
        return None


def ingress_status(item: dict[str, Any]) -> dict[str, Any]:
    metadata = item.get("metadata", {})
    spec = item.get("spec", {})
    hosts = sorted(
        {
            rule.get("host", "").lower()
            for rule in spec.get("rules", []) or []
            if rule.get("host")
        }
    )
    backends = []
    for rule in spec.get("rules", []) or []:
        for path in rule.get("http", {}).get("paths", []) or []:
            service = path.get("backend", {}).get("service", {})
            port = service.get("port", {})
            backends.append(
                {
                    "host": rule.get("host", "").lower(),
                    "path": path.get("path", "/"),
                    "service": service.get("name", ""),
                    "port": port.get("name", port.get("number")),
                }
            )
    addresses = []
    for address in (
        item.get("status", {}).get("loadBalancer", {}).get("ingress", []) or []
    ):
        addresses.append(address.get("hostname") or address.get("ip"))
    tls_hosts = {
        host.lower()
        for tls in spec.get("tls", []) or []
        for host in tls.get("hosts", []) or []
    }
    return {
        "name": metadata.get("name", ""),
        "hosts": hosts,
        "tlsHosts": sorted(tls_hosts),
        "loadBalancerAddresses": sorted(value for value in addresses if value),
        "backends": backends,
    }


def dns_health(host: str) -> dict[str, Any]:
    try:
        addresses = sorted(
            {
                str(ipaddress.ip_address(entry[4][0]))
                for entry in socket.getaddrinfo(host, None)
            }
        )
        return {"host": host, "status": "resolved", "addresses": addresses}
    except (OSError, ValueError):
        return {"host": host, "status": "failed", "addresses": []}


def tls_health(host: str, port: int, timeout: int) -> dict[str, Any]:
    context = ssl.create_default_context()
    try:
        with socket.create_connection((host, port), timeout=timeout) as raw:
            with context.wrap_socket(raw, server_hostname=host) as connection:
                certificate = connection.getpeercert()
                expires = certificate.get("notAfter")
                expires_at = (
                    isoformat(
                        dt.datetime.fromtimestamp(
                            ssl.cert_time_to_seconds(expires), dt.timezone.utc
                        )
                    )
                    if expires
                    else None
                )
                return {
                    "host": host,
                    "port": port,
                    "status": "valid",
                    "expiresAt": expires_at,
                    "protocol": connection.version(),
                    "cipher": connection.cipher()[0] if connection.cipher() else None,
                }
    except (OSError, ssl.SSLError, ValueError):
        return {"host": host, "port": port, "status": "failed"}


def backend_health(url: str, timeout: int) -> tuple[dict[str, Any], list[dict[str, str]]]:
    validate_url(url)
    parsed = urlsplit(url)
    port = parsed.port or (443 if parsed.scheme == "https" else 80)
    connection_type = (
        http.client.HTTPSConnection if parsed.scheme == "https"
        else http.client.HTTPConnection
    )
    path = parsed.path or "/"
    correlations: list[dict[str, str]] = []
    try:
        connection = connection_type(parsed.hostname, port, timeout=timeout)
        connection.request("GET", path, headers={"User-Agent": "support-bundle/1"})
        response = connection.getresponse()
        for header in CORRELATION_HEADERS:
            value = response.getheader(header)
            if value and len(value) <= 256 and not SENSITIVE_TEXT.search(value):
                correlations.append({"source": url, "header": header, "value": value})
        response.close()
        connection.close()
        return (
            {
                "url": url,
                "status": "reachable",
                "httpStatus": response.status,
            },
            correlations,
        )
    except (OSError, ssl.SSLError, http.client.HTTPException):
        return {"url": url, "status": "failed"}, correlations


def release_evidence_file(path: pathlib.Path) -> dict[str, Any]:
    with path.open(encoding="utf-8") as stream:
        data = json.load(stream)
    if not isinstance(data, dict):
        raise CollectionError("release evidence must be a JSON object")
    release = data.get("release", {})
    upgrade_restore = data.get("upgradeRestore", {})
    return {
        "schemaVersion": data.get("schemaVersion"),
        "releaseDecision": data.get("releaseDecision"),
        "release": {
            "chartVersion": release.get("chartVersion"),
            "imageManifestSha256": release.get("imageManifestSha256"),
        },
        "upgradeRestore": {
            key: {
                field: upgrade_restore.get(key, {}).get(field)
                for field in ("result", "chartVersion", "artifactSha256")
            }
            for key in ("upgrade", "restore")
        },
        "sourceSha256": hashlib.sha256(path.read_bytes()).hexdigest(),
    }


def collect(options: Options, runner: CommandRunner) -> tuple[dict[str, Any], dict[str, Any]]:
    errors: list[dict[str, str]] = []

    def attempt(category: str, function: Any, default: Any) -> Any:
        try:
            return function()
        except (
            CollectionError,
            OSError,
            ValueError,
            json.JSONDecodeError,
            subprocess.TimeoutExpired,
        ):
            errors.append({"category": category, "error": "collection unavailable"})
            return default

    helm = helm_base(options)
    kubectl = kubectl_base(options)

    status = attempt(
        "helm-status",
        lambda: runner.run_json(
            helm
            + [
                "status",
                options.release,
                "--namespace",
                options.namespace,
                "--output",
                "json",
            ]
        ),
        {},
    )
    chart = status.get("chart", {}).get("metadata", {}) if isinstance(status, dict) else {}
    info = status.get("info", {}) if isinstance(status, dict) else {}
    versions = {
        "release": status.get("name", options.release) if isinstance(status, dict) else options.release,
        "namespace": options.namespace,
        "revision": status.get("version") if isinstance(status, dict) else None,
        "releaseStatus": info.get("status"),
        "chart": chart.get("name"),
        "chartVersion": chart.get("version"),
        "appVersion": chart.get("appVersion") or chart.get("app_version"),
        "lastDeployed": info.get("last_deployed"),
    }

    values = attempt(
        "helm-values-fingerprint",
        lambda: runner.run_json(
            helm
            + [
                "get",
                "values",
                options.release,
                "--namespace",
                options.namespace,
                "--all",
                "--output",
                "json",
            ]
        ),
        {},
    )
    config_fingerprint = configuration_fingerprint(values)

    workloads_raw = attempt(
        "workloads",
        lambda: runner.run_json(
            kubectl
            + [
                "get",
                "deployments.apps,statefulsets.apps,daemonsets.apps",
                "--selector",
                options.selector,
                "--output",
                "json",
            ]
        ),
        {"items": []},
    )
    pods_raw = attempt(
        "pods",
        lambda: runner.run_json(
            kubectl
            + [
                "get",
                "pods",
                "--selector",
                options.selector,
                "--output",
                "json",
            ]
        ),
        {"items": []},
    )
    jobs_raw = attempt(
        "jobs",
        lambda: runner.run_json(
            kubectl
            + [
                "get",
                "jobs.batch",
                "--selector",
                options.selector,
                "--output",
                "json",
            ]
        ),
        {"items": []},
    )
    ingress_raw = attempt(
        "ingresses",
        lambda: runner.run_json(
            kubectl
            + [
                "get",
                "ingresses.networking.k8s.io",
                "--selector",
                options.selector,
                "--output",
                "json",
            ]
        ),
        {"items": []},
    )
    quota_raw = attempt(
        "resource-quotas",
        lambda: runner.run_json(
            kubectl + ["get", "resourcequotas", "--output", "json"]
        ),
        {"items": []},
    )
    metrics_text = attempt(
        "pod-metrics",
        lambda: runner.run_text(
            kubectl
            + [
                "top",
                "pods",
                "--selector",
                options.selector,
                "--no-headers",
            ]
        ),
        "",
    )

    workloads = [workload_status(item) for item in workloads_raw.get("items", [])]
    pods = [pod_status(item) for item in pods_raw.get("items", [])]
    jobs = jobs_raw.get("items", [])
    migration_jobs = [
        job_status(item) for item in jobs if MIGRATION_RE.search(job_search_text(item))
    ]
    backup_jobs = [
        job_status(item) for item in jobs if BACKUP_RE.search(job_search_text(item))
    ]

    completed = [
        timestamp
        for timestamp in (
            parse_timestamp(job.get("completionTime")) for job in backup_jobs
        )
        if timestamp is not None
    ]
    latest_backup = max(completed) if completed else None
    age_hours = (
        round((utc_now() - latest_backup).total_seconds() / 3600, 2)
        if latest_backup
        else None
    )
    backup_status = {
        "jobs": backup_jobs,
        "latestCompletedAt": isoformat(latest_backup) if latest_backup else None,
        "ageHours": age_hours,
        "maximumAgeHours": options.max_backup_age_hours,
        "ageStatus": (
            "unknown"
            if age_hours is None
            else "current"
            if age_hours <= options.max_backup_age_hours
            else "stale"
        ),
    }

    metrics = []
    for line in metrics_text.splitlines():
        fields = line.split()
        if len(fields) >= 3:
            metrics.append({"pod": fields[0], "cpu": fields[1], "memory": fields[2]})
    quotas = [
        {
            "name": item.get("metadata", {}).get("name", ""),
            "hard": item.get("status", {}).get("hard", {}),
            "used": item.get("status", {}).get("used", {}),
        }
        for item in quota_raw.get("items", [])
    ]

    ingresses = [ingress_status(item) for item in ingress_raw.get("items", [])]
    ingress_hosts = sorted(
        {host for ingress in ingresses for host in ingress.get("hosts", [])}
    )
    health_urls = list(options.health_urls)
    if not health_urls:
        health_urls = [
            f"https://{host}{options.health_path}" for host in ingress_hosts
        ]
    dns_results: list[dict[str, Any]] = []
    tls_results: list[dict[str, Any]] = []
    backend_results: list[dict[str, Any]] = []
    correlations: list[dict[str, str]] = []
    if not options.skip_network:
        dns_results = [dns_health(host) for host in ingress_hosts]
        for url in health_urls:
            parsed = urlsplit(validate_url(url))
            if parsed.scheme == "https":
                tls_results.append(
                    tls_health(parsed.hostname or "", parsed.port or 443, options.timeout)
                )
            backend, ids = backend_health(url, options.timeout)
            backend_results.append(backend)
            correlations.extend(ids)

    history = attempt(
        "helm-history",
        lambda: runner.run_json(
            helm
            + [
                "history",
                options.release,
                "--namespace",
                options.namespace,
                "--output",
                "json",
            ]
        ),
        [],
    )
    curated_history = [
        {
            key: item.get(key)
            for key in ("revision", "updated", "status", "chart", "app_version")
        }
        for item in history
        if isinstance(item, dict)
    ]
    supplied_evidence = (
        attempt(
            "release-evidence-file",
            lambda: release_evidence_file(options.release_evidence),  # type: ignore[arg-type]
            None,
        )
        if options.release_evidence
        else None
    )

    documents = {
        "versions.json": versions,
        "configuration-fingerprint.json": config_fingerprint,
        "workload-status.json": {"workloads": workloads, "pods": pods},
        "migration-ledger-status.json": {
            "source": "Kubernetes migration Job status; no database connection attempted",
            "credentialsRead": False,
            "databaseRowsRead": False,
            "jobs": migration_jobs,
        },
        "resource-pressure.json": {
            "podResourceSpecifications": [
                {"pod": pod["name"], "resources": pod["resources"]} for pod in pods
            ],
            "podMetrics": metrics,
            "resourceQuotas": quotas,
        },
        "backup-age.json": backup_status,
        "network-health.json": {
            "ingresses": ingresses,
            "dns": dns_results,
            "tls": tls_results,
            "backends": backend_results,
            "networkChecksSkipped": options.skip_network,
        },
        "correlation-ids.json": {"ids": correlations},
        "release-evidence.json": {
            "helmHistory": curated_history,
            "suppliedEvidence": supplied_evidence,
        },
        "collection-errors.json": {"errors": errors},
    }
    manifest = {
        "schemaVersion": 1,
        "collectorVersion": COLLECTOR_VERSION,
        "collectedAt": isoformat(utc_now()),
        "namespace": options.namespace,
        "release": options.release,
        "selector": options.selector,
        "readOnly": True,
        # Honest accounting: Kubernetes Secrets are never requested directly,
        # but Helm reads its release-storage Secret for status, values and
        # history. Only curated fields leave memory.
        "secretResourcesRead": helm_storage_reads_secrets(helm_driver()),
        "secretResourcesReadBy": (
            ["helm-release-storage"]
            if helm_storage_reads_secrets(helm_driver())
            else []
        ),
        "helmStorageDriver": helm_driver(),
        "kubernetesSecretsCollected": False,
        "secretPayloadsIncluded": False,
        "passwordBearingUrlsBlocked": True,
        "rawLogsIncluded": False,
        "rawManifestsIncluded": False,
        "rawHelmValuesIncluded": False,
    }
    return documents, manifest


def write_json(path: pathlib.Path, value: Any) -> None:
    path.write_text(
        json.dumps(value, indent=2, sort_keys=True, ensure_ascii=True) + "\n",
        encoding="utf-8",
    )
    path.chmod(0o600)


def scan_tree(root: pathlib.Path) -> list[dict[str, Any]]:
    findings = []
    for path in sorted(item for item in root.rglob("*") if item.is_file()):
        text = path.read_text(encoding="utf-8", errors="replace")
        for line_number, line in enumerate(text.splitlines(), 1):
            categories = []
            if password_bearing_url(line):
                categories.append("password-bearing-url")
            if SENSITIVE_TEXT.search(line):
                categories.append("credential-material")
            if ASSIGNMENT_CREDENTIAL.search(line):
                categories.append("credential-assignment")
            for category in sorted(set(categories)):
                findings.append(
                    {
                        "file": str(path.relative_to(root)),
                        "line": line_number,
                        "category": category,
                    }
                )
    return findings


def add_normalized_tree(archive: tarfile.TarFile, root: pathlib.Path) -> None:
    top = tarfile.TarInfo("support-bundle")
    top.type = tarfile.DIRTYPE
    top.mode = 0o755
    top.uid = top.gid = 0
    top.uname = top.gname = "root"
    top.mtime = 0
    archive.addfile(top)
    for path in sorted(root.rglob("*")):
        relative = pathlib.PurePosixPath("support-bundle") / path.relative_to(root)
        info = tarfile.TarInfo(str(relative))
        info.uid = info.gid = 0
        info.uname = info.gname = "root"
        info.mtime = 0
        if path.is_dir():
            info.type = tarfile.DIRTYPE
            info.mode = 0o755
            archive.addfile(info)
        elif path.is_file():
            info.type = tarfile.REGTYPE
            info.mode = 0o644
            info.size = path.stat().st_size
            with path.open("rb") as stream:
                archive.addfile(info, stream)
        else:
            raise CollectionError("staging tree contains an unsupported file type")


def create_archive(root: pathlib.Path, destination: pathlib.Path) -> pathlib.Path:
    temporary = destination.with_suffix(destination.suffix + ".tmp")
    try:
        with temporary.open("wb") as raw:
            with gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0) as compressed:
                with tarfile.open(fileobj=compressed, mode="w") as archive:
                    add_normalized_tree(archive, root)
        temporary.chmod(0o600)
        os.replace(temporary, destination)
    finally:
        temporary.unlink(missing_ok=True)
    digest = hashlib.sha256(destination.read_bytes()).hexdigest()
    checksum = destination.with_name(destination.name + ".sha256")
    checksum.write_text(f"{digest}  {destination.name}\n", encoding="ascii")
    checksum.chmod(0o644)
    return checksum


def parse_args(argv: list[str]) -> Options:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--namespace", "-n", required=True)
    parser.add_argument("--release", "-r", required=True)
    parser.add_argument("--context")
    parser.add_argument("--selector")
    parser.add_argument("--output-dir", type=pathlib.Path, default=pathlib.Path.cwd())
    parser.add_argument("--health-url", action="append", default=[])
    parser.add_argument("--health-path", default="/health")
    parser.add_argument("--timeout", type=int, default=15)
    parser.add_argument("--skip-network", action="store_true")
    parser.add_argument("--release-evidence", type=pathlib.Path)
    parser.add_argument("--max-backup-age-hours", type=int, default=24)
    args = parser.parse_args(argv)
    dns_label = re.compile(r"^[a-z0-9](?:[-a-z0-9]*[a-z0-9])?$")
    release_name = re.compile(r"^[a-z0-9](?:[-a-z0-9.]*[a-z0-9])?$")
    if not dns_label.fullmatch(args.namespace):
        parser.error("--namespace must be a DNS label")
    if not release_name.fullmatch(args.release):
        parser.error("--release contains unsupported characters")
    if args.timeout < 1 or args.max_backup_age_hours < 1:
        parser.error("timeout and backup age must be positive")
    if not args.health_path.startswith("/") or any(
        char in args.health_path for char in "\r\n?#"
    ):
        parser.error("--health-path must be a path without query or fragment")
    try:
        health_urls = [validate_url(value) for value in args.health_url]
    except CollectionError as error:
        parser.error(str(error))
    return Options(
        namespace=args.namespace,
        release=args.release,
        context=args.context,
        selector=args.selector or f"app.kubernetes.io/instance={args.release}",
        output_dir=args.output_dir.resolve(),
        health_urls=health_urls,
        health_path=args.health_path,
        timeout=args.timeout,
        skip_network=args.skip_network,
        release_evidence=args.release_evidence,
        max_backup_age_hours=args.max_backup_age_hours,
    )


def main(argv: list[str] | None = None) -> int:
    os.umask(0o077)
    options = parse_args(sys.argv[1:] if argv is None else argv)
    options.output_dir.mkdir(parents=True, exist_ok=True)
    timestamp = utc_now().strftime("%Y%m%dT%H%M%SZ")
    archive = options.output_dir / (
        f"support-bundle-{options.release}-{timestamp}.tar.gz"
    )
    runner = CommandRunner(options.timeout)
    try:
        with tempfile.TemporaryDirectory(
            prefix=".support-bundle-", dir=options.output_dir
        ) as temporary:
            staging = pathlib.Path(temporary)
            documents, manifest = collect(options, runner)
            for filename, document in documents.items():
                write_json(staging / filename, document)
            manifest["files"] = {
                path.name: hashlib.sha256(path.read_bytes()).hexdigest()
                for path in sorted(staging.iterdir())
                if path.is_file()
            }
            write_json(staging / "manifest.json", manifest)
            findings = scan_tree(staging)
            if findings:
                categories = sorted({item["category"] for item in findings})
                raise CollectionError(
                    "credential scan blocked archive creation: " + ", ".join(categories)
                )
            checksum = create_archive(staging, archive)
    except CollectionError as error:
        archive.unlink(missing_ok=True)
        print(f"support bundle failed: {error}", file=sys.stderr)
        return 1
    print(str(archive))
    print(str(checksum))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
