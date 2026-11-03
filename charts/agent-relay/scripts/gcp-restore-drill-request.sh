#!/usr/bin/env bash
# Schedule an isolated restore drill without restoring or cutting over traffic.

set -Eeuo pipefail
umask 077

PROGRAM="${0##*/}"
: "${GCS_ARCHIVE_BUCKET:?GCS_ARCHIVE_BUCKET is required}"
: "${HELM_RELEASE:?HELM_RELEASE is required}"

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
    "gs://${GCS_ARCHIVE_BUCKET}/${ARCHIVE_PREFIX}/ar-*/COMPLETE" |
    LC_ALL=C sort | tail -n 1
)"
[[ -n "$latest" ]] || {
  echo "$PROGRAM: no complete recovery set is available for a drill" >&2
  exit 1
}

recovery_id="${latest%/COMPLETE}"
recovery_id="${recovery_id##*/}"
[[ "$recovery_id" =~ ^ar-[0-9]{8}T[0-9]{6}Z-[a-z0-9]{1,8}$ ]] || {
  echo "$PROGRAM: selected recovery ID has an unsafe format" >&2
  exit 1
}

uid_suffix="${POD_UID:-manual}"
uid_suffix="$(tr '[:upper:]' '[:lower:]' <<<"$uid_suffix" | tr -cd 'a-z0-9' | cut -c1-8)"
[[ -n "$uid_suffix" ]] || uid_suffix="unknown"
requested_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
drill_id="drill-$(date -u +%Y%m%dT%H%M%SZ)-${uid_suffix}"
request_uri="gs://${GCS_ARCHIVE_BUCKET}/${ARCHIVE_PREFIX}/${recovery_id}/drills/${drill_id}/request.json"

python3 - "$workdir/request.json" "$drill_id" "$recovery_id" \
  "$HELM_RELEASE" "$requested_at" <<'PY'
import json
import sys

path, drill_id, recovery_id, release, requested_at = sys.argv[1:]
with open(path, "w", encoding="utf-8") as stream:
    json.dump(
        {
            "schemaVersion": 1,
            "drillId": drill_id,
            "recoveryId": recovery_id,
            "status": "REQUESTED",
            "requestedAt": requested_at,
            "sourceRelease": release,
            "requirements": {
                "isolated": True,
                "automaticProductionCutover": False,
                "allVerificationGatesRequired": True,
            },
        },
        stream,
        indent=2,
        sort_keys=True,
    )
    stream.write("\n")
PY

# Create-only: the request is the immutable identity record-restore-drill.sh
# checks, so never replace an existing one (for example two manual runs in
# the same second), even on a bucket without a locked retention policy.
gcloud storage cp --if-generation-match=0 "$workdir/request.json" "$request_uri" >/dev/null
printf 'RESTORE_DRILL_REQUEST=PASS drill_id=%s recovery_id=%s request=%s\n' \
  "$drill_id" "$recovery_id" "$request_uri"
