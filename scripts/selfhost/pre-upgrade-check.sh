#!/usr/bin/env bash
#
# Read-only gate for an Agent Relay Helm upgrade. The evidence files must not
# contain credentials or Secret values.

set -euo pipefail

PROGRAM="${0##*/}"
NAMESPACE=""
RELEASE=""
CONTEXT=""
TARGET_CHART=""
BACKUP_EVIDENCE=""
RESTORE_EVIDENCE=""
COMPATIBILITY_EVIDENCE=""
MAX_BACKUP_AGE_HOURS=24
MAX_RESTORE_AGE_HOURS=720
MAX_COMPATIBILITY_AGE_HOURS=168

usage() {
  cat <<'EOF'
Usage:
  pre-upgrade-check.sh --namespace NAMESPACE --release RELEASE \
    --backup-evidence FILE --restore-evidence FILE \
    --compatibility-evidence FILE [options]

Required:
  -n, --namespace NAME                 Kubernetes namespace
  -r, --release NAME                   Existing Helm release
      --target-chart CHART             Reviewed local chart path or chart ref
      --backup-evidence FILE           Pre-upgrade backup evidence JSON
      --restore-evidence FILE          Isolated restore evidence JSON
      --compatibility-evidence FILE    Migration compatibility evidence JSON

Options:
      --context NAME                   kubectl/Helm context
      --max-backup-age-hours HOURS     Default: 24
      --max-restore-age-hours HOURS    Default: 720
      --max-compatibility-age-hours H  Default: 168
  -h, --help

This command is read-only. It verifies that the evidence matches the currently
deployed Helm revision and that every migration or backup Job is Complete=True.
It does not run a backup, restore, migration, upgrade, or rollback.
EOF
}

die() {
  printf '%s: %s\n' "$PROGRAM" "$*" >&2
  exit 1
}

require_value() {
  (($# >= 2)) || die "$1 requires a value"
}

is_positive_integer() {
  [[ "$1" =~ ^[1-9][0-9]*$ ]]
}

while (($#)); do
  case "$1" in
    -n|--namespace)
      require_value "$@"
      NAMESPACE="$2"
      shift 2
      ;;
    -r|--release)
      require_value "$@"
      RELEASE="$2"
      shift 2
      ;;
    --context)
      require_value "$@"
      CONTEXT="$2"
      shift 2
      ;;
    --target-chart)
      require_value "$@"
      TARGET_CHART="$2"
      shift 2
      ;;
    --backup-evidence)
      require_value "$@"
      BACKUP_EVIDENCE="$2"
      shift 2
      ;;
    --restore-evidence)
      require_value "$@"
      RESTORE_EVIDENCE="$2"
      shift 2
      ;;
    --compatibility-evidence)
      require_value "$@"
      COMPATIBILITY_EVIDENCE="$2"
      shift 2
      ;;
    --max-backup-age-hours)
      require_value "$@"
      MAX_BACKUP_AGE_HOURS="$2"
      shift 2
      ;;
    --max-restore-age-hours)
      require_value "$@"
      MAX_RESTORE_AGE_HOURS="$2"
      shift 2
      ;;
    --max-compatibility-age-hours)
      require_value "$@"
      MAX_COMPATIBILITY_AGE_HOURS="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

[[ -n "$NAMESPACE" ]] || die "--namespace is required"
[[ -n "$RELEASE" ]] || die "--release is required"
[[ -n "$TARGET_CHART" ]] || die "--target-chart is required"
[[ "$NAMESPACE" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] ||
  die "--namespace must be a DNS label"
[[ "$RELEASE" =~ ^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$ ]] ||
  die "--release contains unsupported characters"

for setting in \
  MAX_BACKUP_AGE_HOURS \
  MAX_RESTORE_AGE_HOURS \
  MAX_COMPATIBILITY_AGE_HOURS; do
  is_positive_integer "${!setting}" ||
    die "$(tr '[:upper:]' '[:lower:]' <<<"$setting") must be a positive integer"
done

for evidence in \
  "$BACKUP_EVIDENCE" \
  "$RESTORE_EVIDENCE" \
  "$COMPATIBILITY_EVIDENCE"; do
  [[ -n "$evidence" ]] || die "all three evidence files are required"
  [[ -r "$evidence" ]] || die "evidence file is not readable: $evidence"
done

for command_name in helm kubectl python3; do
  command -v "$command_name" >/dev/null 2>&1 ||
    die "$command_name is required"
done

HELM=(helm)
KUBECTL=(kubectl)
if [[ -n "$CONTEXT" ]]; then
  HELM+=(--kube-context "$CONTEXT")
  KUBECTL+=(--context "$CONTEXT")
fi

release_json="$(
  "${HELM[@]}" status "$RELEASE" \
    --namespace "$NAMESPACE" --output json 2>/dev/null
)" || die "cannot read Helm release status"

release_summary="$(
  printf '%s' "$release_json" |
    python3 -c '
import json
import sys

data = json.load(sys.stdin)
status = data.get("info", {}).get("status")
revision = data.get("version")
chart = data.get("chart", {}).get("metadata", {}).get("version", "")
if status != "deployed" or not isinstance(revision, int) or revision < 1:
    raise SystemExit(1)
print(f"{revision}\t{chart}")
'
)" || die "release must exist and have status deployed"
IFS=$'\t' read -r current_revision current_chart_version <<<"$release_summary"

target_chart_version="$(
  helm show chart "$TARGET_CHART" 2>/dev/null |
    python3 -c '
import re
import sys

for line in sys.stdin:
    if not line.startswith("version:"):
        continue
    version = line.split(":", 1)[1].strip().strip("\"'\''")
    if re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9.+_-]{0,127}", version):
        print(version)
        raise SystemExit(0)
    break
raise SystemExit(1)
'
)" || die "cannot read a safe version from --target-chart"

evidence_summary="$(
  python3 - \
    "$BACKUP_EVIDENCE" \
    "$RESTORE_EVIDENCE" \
    "$COMPATIBILITY_EVIDENCE" \
    "$RELEASE" \
    "$current_revision" \
    "$target_chart_version" \
    "$MAX_BACKUP_AGE_HOURS" \
    "$MAX_RESTORE_AGE_HOURS" \
    "$MAX_COMPATIBILITY_AGE_HOURS" <<'PY'
import datetime
import json
import pathlib
import re
import sys

(
    backup_path,
    restore_path,
    compatibility_path,
    release,
    revision_text,
    expected_target,
    max_backup_age,
    max_restore_age,
    max_compatibility_age,
) = sys.argv[1:]
revision = int(revision_text)
now = datetime.datetime.now(datetime.timezone.utc)


def load(path):
    with pathlib.Path(path).open(encoding="utf-8") as stream:
        value = json.load(stream)
    if not isinstance(value, dict):
        raise ValueError(f"{path}: root must be an object")
    return value


def require(data, key, expected=None):
    if key not in data:
        raise ValueError(f"missing field: {key}")
    value = data[key]
    if expected is not None and value != expected:
        raise ValueError(f"{key} must equal {expected!r}")
    return value


def check_timestamp(data, key, max_age_hours):
    value = require(data, key)
    if not isinstance(value, str):
        raise ValueError(f"{key} must be an RFC3339 string")
    rendered = value[:-1] + "+00:00" if value.endswith("Z") else value
    timestamp = datetime.datetime.fromisoformat(rendered)
    if timestamp.tzinfo is None:
        raise ValueError(f"{key} must include a timezone")
    timestamp = timestamp.astimezone(datetime.timezone.utc)
    age = now - timestamp
    if age < datetime.timedelta(minutes=-5):
        raise ValueError(f"{key} is in the future")
    if age > datetime.timedelta(hours=int(max_age_hours)):
        raise ValueError(f"{key} is older than {max_age_hours} hours")


try:
    backup = load(backup_path)
    restore = load(restore_path)
    compatibility = load(compatibility_path)

    recovery_id = require(backup, "recoveryId")
    if not isinstance(recovery_id, str) or not re.fullmatch(
        r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}", recovery_id
    ):
        raise ValueError("recoveryId has an unsafe format")
    require(backup, "status", "PASS")
    require(backup, "providerStatus", "SUCCESSFUL")
    require(backup, "sourceRelease", release)
    require(backup, "sourceRevision", revision)
    require(backup, "writesQuiesced", True)
    require(backup, "artifactsComplete", True)
    check_timestamp(backup, "completedAt", max_backup_age)

    require(restore, "recoveryId", recovery_id)
    require(restore, "status", "PASS")
    require(restore, "isolated", True)
    require(restore, "allVerificationGatesPassed", True)
    check_timestamp(restore, "completedAt", max_restore_age)

    require(compatibility, "status", "PASS")
    require(compatibility, "sourceRevision", revision)
    target = require(compatibility, "targetChartVersion", expected_target)
    migration = require(compatibility, "databaseMigration")
    if migration not in {"backward-compatible", "forward-only"}:
        raise ValueError(
            "databaseMigration must be backward-compatible or forward-only"
        )
    rollback = require(compatibility, "rollbackStrategy")
    if rollback not in {"database-restore", "side-by-side-restore"}:
        raise ValueError(
            "rollbackStrategy must be database-restore or side-by-side-restore"
        )
    check_timestamp(compatibility, "reviewedAt", max_compatibility_age)
except (OSError, ValueError, json.JSONDecodeError) as error:
    print(error, file=sys.stderr)
    raise SystemExit(1)

print(f"{recovery_id}\t{target}\t{migration}\t{rollback}")
PY
)" || die "backup, restore, or compatibility evidence failed validation"
IFS=$'\t' read -r recovery_id target_chart migration_class rollback_strategy \
  <<<"$evidence_summary"

job_json="$(
  "${KUBECTL[@]}" --namespace "$NAMESPACE" get jobs.batch \
    -l "app.kubernetes.io/instance=$RELEASE" -o json 2>/dev/null
)" || die "cannot inspect migration and backup Jobs"

job_summary="$(
  printf '%s' "$job_json" |
    python3 -c '
import json
import re
import sys

data = json.load(sys.stdin)
matched = active = failed = incomplete = 0
for item in data.get("items", []):
    metadata = item.get("metadata", {})
    labels = metadata.get("labels", {})
    text = " ".join(
        [
            metadata.get("name", ""),
            labels.get("app.kubernetes.io/component", ""),
            labels.get("app.kubernetes.io/name", ""),
            labels.get("job-type", ""),
        ]
    )
    if not re.search(r"(migrat|schema|backup)", text, re.I):
        continue
    matched += 1
    status = item.get("status", {})
    conditions = {
        condition.get("type"): condition.get("status")
        for condition in status.get("conditions", [])
    }
    # Only Complete=True proves the Job ran to completion. A Job that
    # succeeded after a retried pod keeps failed>0 but is complete; a
    # suspended or not-yet-synced Job has no conditions and is not.
    if conditions.get("Complete") == "True":
        continue
    if status.get("active", 0) > 0:
        active += 1
    elif conditions.get("Failed") == "True":
        failed += 1
    else:
        incomplete += 1
print(matched, active, failed, incomplete)
'
)" || die "cannot parse migration and backup Job status"
read -r matched_jobs active_jobs failed_jobs incomplete_jobs <<<"$job_summary"
((active_jobs == 0)) || die "migration or backup Jobs are active"
((failed_jobs == 0)) || die "migration or backup Jobs have failed"
((incomplete_jobs == 0)) ||
  die "migration or backup Jobs are not Complete=True (suspended or not yet started)"

printf '%s: release=%s revision=%s chart=%s status=deployed\n' \
  "$PROGRAM" "$RELEASE" "$current_revision" "${current_chart_version:-unknown}"
printf '%s: recovery_id=%s backup=PASS isolated_restore=PASS\n' \
  "$PROGRAM" "$recovery_id"
printf '%s: target_chart=%s migration=%s rollback_strategy=%s\n' \
  "$PROGRAM" "$target_chart" "$migration_class" "$rollback_strategy"
printf '%s: migration_or_backup_jobs=%s complete=%s\n' \
  "$PROGRAM" "$matched_jobs" "$matched_jobs"
printf '%s: OK\n' "$PROGRAM"
