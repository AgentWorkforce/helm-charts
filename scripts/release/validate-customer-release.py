#!/usr/bin/env python3
"""Fail-closed production gate for the Agent Relay customer bundle."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
import sys
from pathlib import Path
from typing import Any


DIGEST = re.compile(r"^sha256:[0-9a-f]{64}$")
REVISION = re.compile(r"^[0-9a-f]{40,64}$")
APPROVED_LICENSES = {"approved", "approved-upstream"}
APPROVED_ACQUISITION = {
    "available-public",
    "approved-entitlement",
    "promoted-customer-registry",
}
APPROVED_IMAGE = {"approved", "customer-ready"}
REQUIRED_IMAGE_PLATFORMS = {"linux/amd64", "linux/arm64"}
DESKTOP_PLATFORMS = {
    "darwin/amd64",
    "darwin/arm64",
    "linux/amd64",
    "linux/arm64",
}
PROOF_OR_PRIVATE = re.compile(
    r"(?:^|[./_-])(proof|conformance)(?:[./_-]|$)|"
    r"(?:^|[./_-])private(?:[./_-]|$)|<|>",
    re.IGNORECASE,
)
HOOK = re.compile(r"""["']?helm\.sh/hook["']?\s*:\s*["']?([^"'\s#}]+)""")


class Gate:
    def __init__(self) -> None:
        self.errors: list[str] = []

    def reject(self, category: str, detail: str) -> None:
        self.errors.append(f"{category}: {detail}")

    def require(self, condition: bool, category: str, detail: str) -> None:
        if not condition:
            self.reject(category, detail)


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def load_json(path: Path, gate: Gate, label: str) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        gate.reject("schema", f"cannot read {label} {path}: {exc}")
        return {}


def load_yaml(path: Path, gate: Gate) -> Any:
    try:
        process = subprocess.run(
            ("yq", "-o=json", "explode(.)", str(path)),
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        return json.loads(process.stdout)
    except FileNotFoundError:
        gate.reject("schema", "yq v4 is required to read customer-images.yaml")
    except (subprocess.CalledProcessError, json.JSONDecodeError) as exc:
        detail = (
            exc.stderr.strip()
            if isinstance(exc, subprocess.CalledProcessError)
            else str(exc)
        )
        gate.reject("schema", f"cannot parse {path}: {detail}")
    return {}


def mapping(value: Any) -> dict[str, Any]:
    return value if isinstance(value, dict) else {}


def sequence(value: Any) -> list[Any]:
    return value if isinstance(value, list) else []


def text(value: Any) -> str:
    return value if isinstance(value, str) else ""


def safe_input(root: Path, value: str, gate: Gate, label: str) -> Path:
    candidate = Path(value)
    if not candidate.is_absolute():
        candidate = root / candidate
    try:
        resolved = candidate.resolve(strict=True)
        resolved.relative_to(root)
    except (OSError, ValueError):
        gate.reject("schema", f"{label} must be an existing path beneath {root}")
        return candidate
    if "dist" in resolved.relative_to(root).parts:
        gate.reject("schema", f"{label} may not use dist/")
    return resolved


def validate_evidence_shape(evidence: Any, schema: Any, gate: Gate) -> None:
    e = mapping(evidence)
    s = mapping(schema)
    gate.require(
        s.get("$schema") == "https://json-schema.org/draft/2020-12/schema",
        "schema",
        "release evidence schema must use JSON Schema 2020-12",
    )
    gate.require(s.get("type") == "object", "schema", "schema root must be object")
    required = sequence(s.get("required"))
    for key in required:
        gate.require(key in e, "schema", f"release evidence is missing {key}")
    gate.require(e.get("schemaVersion") == 1, "schema", "schemaVersion must be 1")
    for key in (
        "release",
        "licenses",
        "relayHistoryMigrations",
        "upgradeRestore",
        "desktop",
    ):
        gate.require(
            isinstance(e.get(key), dict),
            "schema",
            f"release evidence {key} must be an object",
        )


def validate_controls(evidence: dict[str, Any], gate: Gate) -> None:
    gate.require(
        evidence.get("releaseDecision") == "approved",
        "release-decision",
        "releaseDecision must be approved",
    )
    release = mapping(evidence.get("release"))
    branch = mapping(release.get("branchControls"))
    gate.require(text(branch.get("branch")) != "", "branch-controls", "branch missing")
    gate.require(branch.get("protected") is True, "branch-controls", "branch not protected")
    gate.require(
        branch.get("requiresPullRequest") is True,
        "branch-controls",
        "pull requests are not required",
    )
    gate.require(
        isinstance(branch.get("requiredApprovals"), int)
        and branch["requiredApprovals"] >= 1,
        "branch-controls",
        "at least one branch approval is required",
    )
    checks = sequence(branch.get("requiredStatusChecks"))
    gate.require(
        "customer-release-gate" in checks,
        "branch-controls",
        "customer-release-gate is not a required status check",
    )
    environment = mapping(release.get("environmentControls"))
    gate.require(
        text(environment.get("name")) != "",
        "environment-controls",
        "release environment missing",
    )
    gate.require(
        environment.get("protected") is True,
        "environment-controls",
        "release environment not protected",
    )
    gate.require(
        isinstance(environment.get("requiredApprovals"), int)
        and environment["requiredApprovals"] >= 1,
        "environment-controls",
        "at least one environment approval is required",
    )
    gate.require(
        environment.get("preventsSelfReview") is True,
        "environment-controls",
        "environment permits self-review",
    )


def validate_license_decisions(
    evidence: dict[str, Any], images: list[Any], gate: Gate
) -> None:
    decisions = {}
    for item in sequence(mapping(evidence.get("licenses")).get("firstParty")):
        row = mapping(item)
        identifier = text(row.get("id"))
        if identifier:
            if identifier in decisions:
                gate.reject("first-party-license", f"duplicate decision for {identifier}")
            decisions[identifier] = row
    required = {"helm-charts"}
    for item in images:
        image = mapping(item)
        source_repo = text(mapping(image.get("source")).get("repository")).lower()
        if image.get("active") is True and "agentworkforce/" in source_repo:
            required.add(text(image.get("id")))
    for identifier in sorted(required):
        row = mapping(decisions.get(identifier))
        gate.require(
            row.get("decision") == "approved"
            and text(row.get("spdx")) != ""
            and text(row.get("evidence")) != "",
            "first-party-license",
            f"{identifier} lacks an approved SPDX license decision and evidence",
        )


def validate_images(manifest: dict[str, Any], gate: Gate) -> list[Any]:
    gate.require(
        manifest.get("apiVersion") == "selfhost.agentrelay.com/v1alpha1"
        and manifest.get("kind") == "CustomerImageSourceManifest",
        "images-manifest",
        "unexpected customer image manifest identity",
    )
    gate.require(
        manifest.get("status") == "ready",
        "hard-blocker",
        "customer-images status is not ready",
    )
    for blocker in sequence(manifest.get("blockers")):
        row = mapping(blocker)
        if row.get("severity") == "hard":
            gate.reject(
                "hard-blocker",
                f"{text(row.get('id')) or '(unnamed)'} remains unresolved",
            )

    images = sequence(manifest.get("images"))
    gate.require(bool(images), "images-manifest", "images list is empty")
    ids: set[str] = set()
    for item in images:
        image = mapping(item)
        if image.get("active") is not True:
            continue
        identifier = text(image.get("id")) or "(unnamed)"
        if identifier in ids:
            gate.reject("images-manifest", f"duplicate active image id {identifier}")
        ids.add(identifier)
        current = mapping(image.get("current"))
        repository = text(current.get("repository"))
        digest = text(current.get("digest"))
        gate.require(
            repository != "" and not PROOF_OR_PRIVATE.search(repository),
            "registry",
            f"{identifier} uses a proof/private/placeholder registry",
        )
        gate.require(
            bool(DIGEST.fullmatch(digest))
            and digest != "sha256:" + ("0" * 64),
            "mutable-image",
            f"{identifier} lacks a non-zero immutable digest",
        )
        for key, value in current.items():
            if "tag" in key.lower() and value not in (None, ""):
                gate.reject("mutable-image", f"{identifier} supplies mutable {key}")

        source = mapping(image.get("source"))
        gate.require(
            bool(REVISION.fullmatch(text(source.get("revision"))))
            and source.get("reproducibleReference") is True,
            "source-revision",
            f"{identifier} is not tied to a reproducible committed revision",
        )
        license_row = mapping(image.get("license"))
        gate.require(
            license_row.get("status") in APPROVED_LICENSES
            and text(license_row.get("spdx")) != ""
            and text(license_row.get("evidence")) != "",
            "image-license",
            f"{identifier} license is not approved",
        )
        platforms = mapping(image.get("platforms"))
        expected = set(sequence(platforms.get("expected")))
        verified = set(sequence(platforms.get("verifiedFromRegistry")))
        gate.require(
            REQUIRED_IMAGE_PLATFORMS <= expected
            and expected <= verified
            and platforms.get("status") == "verified",
            "image-platforms",
            f"{identifier} required platforms are not registry-verified",
        )
        release = mapping(image.get("release"))
        gate.require(
            text(release.get("workflow")) != ""
            and text(release.get("run")) != ""
            and release.get("buildsCommittedRevision") is True,
            "source-revision",
            f"{identifier} lacks a reviewed committed-revision release run",
        )
        gate.require(
            release.get("publishesSbom") is True,
            "sbom",
            f"{identifier} does not publish an SBOM",
        )
        gate.require(
            release.get("publishesProvenance") is True,
            "provenance",
            f"{identifier} does not publish verifiable provenance",
        )
        acquisition = mapping(image.get("customerAcquisition"))
        gate.require(
            acquisition.get("status") in APPROVED_ACQUISITION
            and text(acquisition.get("procedure")) != "",
            "registry",
            f"{identifier} lacks an approved customer acquisition procedure",
        )
        approval = mapping(image.get("approval"))
        gate.require(
            approval.get("status") in APPROVED_IMAGE
            and sequence(approval.get("blockingReasons")) == [],
            "hard-blocker",
            f"{identifier} is not approved for customer release",
        )
    return images


def walk_image_values(value: Any, location: str = "$") -> list[tuple[str, dict[str, Any]]]:
    found: list[tuple[str, dict[str, Any]]] = []
    if isinstance(value, dict):
        if "repository" in value:
            found.append((location, value))
        for key, child in value.items():
            found.extend(walk_image_values(child, f"{location}.{key}"))
    elif isinstance(value, list):
        for index, child in enumerate(value):
            found.extend(walk_image_values(child, f"{location}[{index}]"))
    return found


def validate_values(values: Any, gate: Gate) -> None:
    images = walk_image_values(values)
    gate.require(bool(images), "mutable-image", "release values contain no images")
    for location, image in images:
        repository = text(image.get("repository"))
        digest = text(image.get("digest"))
        gate.require(
            repository != "" and not PROOF_OR_PRIVATE.search(repository),
            "registry",
            f"{location} uses a proof/private/placeholder repository",
        )
        gate.require(
            bool(DIGEST.fullmatch(digest))
            and digest != "sha256:" + ("0" * 64),
            "mutable-image",
            f"{location} is not pinned to a non-zero digest",
        )
        gate.require(
            image.get("tag") in (None, ""),
            "mutable-image",
            f"{location} supplies a mutable tag",
        )


def validate_hooks(scan_root: Path, gate: Gate) -> None:
    charts = scan_root / "charts"
    if not charts.is_dir():
        gate.reject("helm-hooks", f"chart scan root is missing: {charts}")
        return
    for path in sorted(charts.glob("*/templates/**/*")):
        if not path.is_file():
            continue
        try:
            content = path.read_text(encoding="utf-8")
        except UnicodeError:
            continue
        for match in HOOK.finditer(content):
            hooks = {part.strip() for part in match.group(1).split(",")}
            unsupported = sorted(hooks - {"test", "test-success"})
            if unsupported:
                gate.reject(
                    "helm-hooks",
                    f"{path.relative_to(scan_root)} declares {','.join(unsupported)}",
                )


def validate_migrations(
    evidence: dict[str, Any], images: list[Any], gate: Gate
) -> None:
    row = mapping(evidence.get("relayHistoryMigrations"))
    source_count = row.get("sourceCount")
    image_count = row.get("imageCount")
    gate.require(
        isinstance(source_count, int)
        and source_count > 0
        and image_count == source_count,
        "relayhistory-migrations",
        "source and image migration counts must match and be positive",
    )
    history = next(
        (mapping(item) for item in images if mapping(item).get("id") == "relayhistory"),
        {},
    )
    gate.require(
        text(row.get("sourceRevision"))
        == text(mapping(history.get("source")).get("revision")),
        "relayhistory-migrations",
        "migration count revision does not match the RelayHistory image source",
    )
    gate.require(
        text(row.get("evidence")) != "",
        "relayhistory-migrations",
        "migration count evidence is missing",
    )


def validate_test_evidence(
    evidence: dict[str, Any], image_manifest_sha: str, gate: Gate
) -> None:
    records = mapping(evidence.get("upgradeRestore"))
    release_version = text(mapping(evidence.get("release")).get("chartVersion"))
    for name in ("upgrade", "restore"):
        row = mapping(records.get(name))
        gate.require(
            row.get("result") == "pass",
            f"{name}-evidence",
            f"{name} result is not pass",
        )
        gate.require(
            text(row.get("chartVersion")) == release_version
            and text(row.get("evidence")) != ""
            and DIGEST.fullmatch(text(row.get("artifactSha256"))) is not None,
            f"{name}-evidence",
            f"{name} evidence metadata is incomplete or for another chart version",
        )
        gate.require(
            text(row.get("imageManifestSha256")) == image_manifest_sha,
            f"{name}-evidence",
            f"{name} was not tested against this image manifest",
        )


def validate_desktop(evidence: dict[str, Any], gate: Gate) -> None:
    row = mapping(evidence.get("desktop"))
    customer = set(sequence(row.get("customerPlatforms")))
    tested = set(sequence(row.get("testedPlatforms")))
    gate.require(bool(customer), "desktop-platforms", "no customer platform recorded")
    unsupported = sorted(customer - DESKTOP_PLATFORMS)
    gate.require(
        not unsupported,
        "desktop-platforms",
        f"unsupported customer platform(s): {', '.join(unsupported)}",
    )
    gate.require(
        customer <= tested,
        "desktop-platforms",
        "every customer Desktop platform must have passing evidence",
    )
    gate.require(
        row.get("result") == "pass" and text(row.get("evidence")) != "",
        "desktop-platforms",
        "Desktop platform evidence is missing or failed",
    )


def validate_git(root: Path, gate: Gate) -> None:
    try:
        top = subprocess.run(
            ("git", "-C", str(root), "rev-parse", "--show-toplevel"),
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        ).stdout.strip()
        gate.require(
            Path(top).resolve() == root,
            "source-worktree",
            "root is not the Git worktree root",
        )
        status = subprocess.run(
            (
                "git",
                "-C",
                str(root),
                "status",
                "--porcelain=v1",
                "--untracked-files=all",
                "--",
                ".",
                ":(exclude)dist",
            ),
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        ).stdout
        gate.require(
            status == "",
            "source-worktree",
            "tracked release source has uncommitted changes",
        )
    except (FileNotFoundError, subprocess.CalledProcessError) as exc:
        gate.reject("source-worktree", f"cannot inspect Git worktree: {exc}")


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(
        description="Validate all production customer-bundle release evidence."
    )
    result.add_argument("--root", default=".")
    result.add_argument(
        "--evidence", default="self-hosted/customer-release-evidence.json"
    )
    result.add_argument(
        "--schema", default="self-hosted/customer-release-evidence.schema.json"
    )
    result.add_argument(
        "--customer-images", default="self-hosted/customer-images.yaml"
    )
    result.add_argument(
        "--scan-root",
        help="root containing charts/; defaults to --root (fixture tests only)",
    )
    result.add_argument(
        "--require-clean",
        action="store_true",
        help="also require a clean Git worktree, excluding dist/",
    )
    return result


def main() -> int:
    args = parser().parse_args()
    root = Path(args.root).expanduser().resolve()
    gate = Gate()
    evidence_path = safe_input(root, args.evidence, gate, "evidence")
    schema_path = safe_input(root, args.schema, gate, "schema")
    images_path = safe_input(root, args.customer_images, gate, "customer images")
    scan_root = safe_input(root, args.scan_root or ".", gate, "scan root")
    evidence = load_json(evidence_path, gate, "release evidence")
    schema = load_json(schema_path, gate, "release evidence schema")
    manifest = load_yaml(images_path, gate)
    validate_evidence_shape(evidence, schema, gate)
    evidence_map = mapping(evidence)
    validate_controls(evidence_map, gate)
    images = validate_images(mapping(manifest), gate)
    validate_license_decisions(evidence_map, images, gate)

    release = mapping(evidence_map.get("release"))
    chart_path = scan_root / "charts/agent-relay/Chart.yaml"
    chart = load_yaml(chart_path, gate)
    gate.require(
        text(mapping(chart).get("version")) == text(release.get("chartVersion")),
        "release-version",
        "release evidence chartVersion does not match charts/agent-relay/Chart.yaml",
    )
    values_file = safe_input(root, text(release.get("valuesFile")), gate, "valuesFile")
    values = load_yaml(values_file, gate)
    validate_values(values, gate)
    validate_hooks(scan_root, gate)
    validate_migrations(evidence_map, images, gate)
    try:
        manifest_sha = "sha256:" + sha256(images_path.read_bytes())
    except OSError:
        manifest_sha = ""
    gate.require(
        text(release.get("imageManifestSha256")) == manifest_sha,
        "images-manifest",
        "release evidence hash does not match customer-images.yaml",
    )
    validate_test_evidence(evidence_map, manifest_sha, gate)
    validate_desktop(evidence_map, gate)
    if args.require_clean:
        validate_git(root, gate)

    if gate.errors:
        for error in gate.errors:
            print(f"ERROR [{error}]", file=sys.stderr)
        print(
            f"customer release gate: FAIL ({len(gate.errors)} error(s))",
            file=sys.stderr,
        )
        return 1
    print(
        "customer release gate: PASS "
        f"(images={len([x for x in images if mapping(x).get('active') is True])})"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
