#!/usr/bin/env bash
# Fail closed unless recent immutable evidence proves an isolated restore drill.

set -Eeuo pipefail
umask 077

PROGRAM="${0##*/}"
: "${GCS_ARCHIVE_BUCKET:?GCS_ARCHIVE_BUCKET is required}"
: "${MAX_DRILL_AGE_DAYS:?MAX_DRILL_AGE_DAYS is required}"
[[ "$MAX_DRILL_AGE_DAYS" =~ ^[0-9]+$ ]] &&
  ((MAX_DRILL_AGE_DAYS > 0 && MAX_DRILL_AGE_DAYS <= 100)) || {
  echo "$PROGRAM: MAX_DRILL_AGE_DAYS must be between 1 and 100" >&2
  exit 1
}

ARCHIVE_PREFIX="${ARCHIVE_PREFIX:-recovery}"
ARCHIVE_PREFIX="${ARCHIVE_PREFIX#/}"
ARCHIVE_PREFIX="${ARCHIVE_PREFIX%/}"
[[ "$ARCHIVE_PREFIX" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]{0,126}$ ]] || {
  echo "$PROGRAM: ARCHIVE_PREFIX has an unsafe format" >&2
  exit 1
}

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

latest="$(
  gcloud storage ls \
    "gs://${GCS_ARCHIVE_BUCKET}/${ARCHIVE_PREFIX}/ar-*/drills/drill-*/PASS.json" |
    LC_ALL=C sort | tail -n 1
)"
[[ -n "$latest" ]] || {
  echo "$PROGRAM: no passing isolated restore-drill evidence exists" >&2
  exit 1
}
gcloud storage cp "$latest" "$workdir/PASS.json" >/dev/null
drill_uri="${latest%/PASS.json}"
recovery_uri="${drill_uri%/drills/*}"
gcloud storage ls "${recovery_uri}/COMPLETE" >/dev/null 2>&1 || {
  echo "$PROGRAM: restore-drill evidence references a recovery set without a COMPLETE marker" >&2
  exit 1
}

python3 - "$workdir/PASS.json" "$MAX_DRILL_AGE_DAYS" "$latest" <<'PY'
import datetime
import json
import re
import sys

path, max_age_text, uri = sys.argv[1:]
with open(path, encoding="utf-8") as stream:
    evidence = json.load(stream)
if not isinstance(evidence, dict):
    raise SystemExit("restore-drill evidence root must be an object")
required = {
    "status": "PASS",
    "isolated": True,
    "allVerificationGatesPassed": True,
    "automaticProductionCutover": False,
}
for key, expected in required.items():
    if evidence.get(key) != expected:
        raise SystemExit(f"restore-drill evidence {key} must equal {expected!r}")
recovery_id = evidence.get("recoveryId")
drill_id = evidence.get("drillId")
if not isinstance(recovery_id, str) or not re.fullmatch(
    r"ar-[0-9]{8}T[0-9]{6}Z-[a-z0-9]{1,8}", recovery_id
):
    raise SystemExit("restore-drill evidence recoveryId has an unsafe format")
if not isinstance(drill_id, str) or not re.fullmatch(
    r"drill-[0-9]{8}T[0-9]{6}Z-[a-z0-9]{1,8}", drill_id
):
    raise SystemExit("restore-drill evidence drillId has an unsafe format")
expected_suffix = f"/{recovery_id}/drills/{drill_id}/PASS.json"
if not uri.endswith(expected_suffix):
    raise SystemExit("restore-drill evidence identity does not match its archive path")
value = evidence.get("completedAt")
if not isinstance(value, str):
    raise SystemExit("restore-drill evidence completedAt must be an RFC3339 string")
rendered = value[:-1] + "+00:00" if value.endswith("Z") else value
completed = datetime.datetime.fromisoformat(rendered)
if completed.tzinfo is None:
    raise SystemExit("restore-drill evidence completedAt must include a timezone")
now = datetime.datetime.now(datetime.timezone.utc)
age = now - completed.astimezone(datetime.timezone.utc)
if age < datetime.timedelta(minutes=-5):
    raise SystemExit("restore-drill evidence completedAt is in the future")
if age > datetime.timedelta(days=int(max_age_text)):
    raise SystemExit("restore-drill evidence is stale")
PY

printf 'RESTORE_DRILL_AUDIT=PASS evidence=%s\n' "$latest"
