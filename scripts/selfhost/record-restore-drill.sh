#!/usr/bin/env bash
#
# Validate operator-produced isolated restore evidence and append it to the
# locked recovery bucket. This script does not restore, route, or cut over
# production traffic.

set -Eeuo pipefail
umask 077

PROGRAM="${0##*/}"
EVIDENCE=""
BUCKET=""
PREFIX="recovery"

usage() {
  cat <<'EOF'
Usage:
  record-restore-drill.sh --evidence FILE --bucket BUCKET [--prefix PREFIX]

The evidence must describe an already-completed isolated restore drill. The
script validates it and creates PASS.json beneath that recovery/drill ID in an
existing locked GCS bucket. It performs no Kubernetes, Cloud SQL, DNS, load
balancer, or production cutover operation.
EOF
}

die() {
  printf '%s: %s\n' "$PROGRAM" "$*" >&2
  exit 1
}

while (($#)); do
  case "$1" in
    --evidence)
      (($# >= 2)) || die "--evidence requires a value"
      EVIDENCE="$2"
      shift 2
      ;;
    --bucket)
      (($# >= 2)) || die "--bucket requires a value"
      BUCKET="$2"
      shift 2
      ;;
    --prefix)
      (($# >= 2)) || die "--prefix requires a value"
      PREFIX="$2"
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

[[ -r "$EVIDENCE" ]] || die "--evidence must name a readable file"
[[ "$BUCKET" =~ ^[a-z0-9][a-z0-9._-]{1,61}[a-z0-9]$ ]] ||
  die "--bucket has an unsafe format"
PREFIX="${PREFIX#/}"
PREFIX="${PREFIX%/}"
[[ "$PREFIX" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]{0,126}$ ]] ||
  die "--prefix has an unsafe format"
command -v gcloud >/dev/null 2>&1 || die "gcloud is required"
command -v python3 >/dev/null 2>&1 || die "python3 is required"

identity="$(
  python3 - "$EVIDENCE" <<'PY'
import datetime
import json
import re
import sys

required_gates = {
    "cloudSql",
    "relaycastIntegrity",
    "relayauthIntegrity",
    "gcsIntegrity",
    "isolatedMessaging",
    "crossWorkspaceDenied",
    "noProductionReferences",
}
with open(sys.argv[1], encoding="utf-8") as stream:
    evidence = json.load(stream)
if not isinstance(evidence, dict):
    raise SystemExit("evidence root must be an object")
required = {
    "status": "PASS",
    "isolated": True,
    "allVerificationGatesPassed": True,
    "automaticProductionCutover": False,
}
for key, expected in required.items():
    if evidence.get(key) != expected:
        raise SystemExit(f"{key} must equal {expected!r}")
recovery_id = evidence.get("recoveryId")
drill_id = evidence.get("drillId")
if not isinstance(recovery_id, str) or not re.fullmatch(
    r"ar-[0-9]{8}T[0-9]{6}Z-[a-z0-9]{1,8}", recovery_id
):
    raise SystemExit("recoveryId has an unsafe format")
if not isinstance(drill_id, str) or not re.fullmatch(
    r"drill-[0-9]{8}T[0-9]{6}Z-[a-z0-9]{1,8}", drill_id
):
    raise SystemExit("drillId has an unsafe format")
approved_by = evidence.get("approvedBy")
if not isinstance(approved_by, str) or not re.fullmatch(
    r"[A-Za-z0-9][A-Za-z0-9@._-]{1,127}", approved_by
):
    raise SystemExit("approvedBy must be a non-secret operator identifier")
gates = evidence.get("verificationGates")
if not isinstance(gates, dict) or set(gates) != required_gates:
    raise SystemExit("verificationGates must contain exactly the documented gates")
if any(value != "PASS" for value in gates.values()):
    raise SystemExit("every verification gate must equal PASS")
completed_text = evidence.get("completedAt")
if not isinstance(completed_text, str):
    raise SystemExit("completedAt must be an RFC3339 string")
rendered = completed_text[:-1] + "+00:00" if completed_text.endswith("Z") else completed_text
completed = datetime.datetime.fromisoformat(rendered)
if completed.tzinfo is None:
    raise SystemExit("completedAt must include a timezone")
now = datetime.datetime.now(datetime.timezone.utc)
age = now - completed.astimezone(datetime.timezone.utc)
if age < datetime.timedelta(minutes=-5) or age > datetime.timedelta(days=7):
    raise SystemExit("completedAt must be within the last seven days")
print(recovery_id, drill_id)
PY
)" || die "restore-drill evidence failed validation"
read -r recovery_id drill_id <<<"$identity"

base="gs://${BUCKET}/${PREFIX}/${recovery_id}/drills/${drill_id}"
gcloud storage ls "${base}/request.json" >/dev/null 2>&1 ||
  die "matching immutable drill request does not exist"
if gcloud storage ls "${base}/PASS.json" >/dev/null 2>&1; then
  die "PASS evidence already exists; immutable evidence is append-only"
fi
gcloud storage cp --if-generation-match=0 "$EVIDENCE" \
  "${base}/PASS.json" >/dev/null

printf '%s: recorded isolated restore evidence at %s/PASS.json\n' \
  "$PROGRAM" "$base"
