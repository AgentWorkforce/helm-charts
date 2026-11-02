#!/usr/bin/env bash
#
# Coordinated, crash-consistent GCP recovery capture. Authentication is
# intentionally delegated to GKE Workload Identity; this script has no
# credential-file or service-account-key path.

set -Eeuo pipefail
umask 077

PROGRAM="${0##*/}"
PHASE="initialization"
COMPLETE=false
WORKDIR="$(mktemp -d)"
STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
HELM_RELEASE="${HELM_RELEASE:-}"
RECOVERY_ID=""
RECOVERY_URI=""

required_env=(
  PROJECT_ID CLOUDSQL_INSTANCE CLOUDSQL_DATABASES GCS_SOURCE_BUCKET
  GCS_ARCHIVE_BUCKET SNAPSHOT_CLASS RELAYCAST_PVC RELAYAUTH_PVC
  KUBERNETES_NAMESPACE HELM_RELEASE RETENTION_DAYS RPO_MINUTES RTO_HOURS
)

die() {
  printf '%s: phase=%s: %s\n' "$PROGRAM" "$PHASE" "$*" >&2
  return 1
}

for name in "${required_env[@]}"; do
  [[ -n "${!name:-}" ]] || die "$name is required"
done

[[ "$PROJECT_ID" =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]$ ]] ||
  die "PROJECT_ID has an unsafe format"
[[ "$CLOUDSQL_INSTANCE" =~ ^[a-z][a-z0-9-]{0,96}[a-z0-9]$ ]] ||
  die "CLOUDSQL_INSTANCE has an unsafe format"
[[ "$GCS_SOURCE_BUCKET" =~ ^[a-z0-9][a-z0-9._-]{1,61}[a-z0-9]$ ]] ||
  die "GCS_SOURCE_BUCKET has an unsafe format"
[[ "$GCS_ARCHIVE_BUCKET" =~ ^[a-z0-9][a-z0-9._-]{1,61}[a-z0-9]$ ]] ||
  die "GCS_ARCHIVE_BUCKET has an unsafe format"
[[ "$GCS_SOURCE_BUCKET" != "$GCS_ARCHIVE_BUCKET" ]] ||
  die "source and immutable archive buckets must differ"
[[ "$RETENTION_DAYS" =~ ^[0-9]+$ ]] && ((RETENTION_DAYS >= 35)) ||
  die "RETENTION_DAYS must be at least 35"
[[ "$RPO_MINUTES" =~ ^[0-9]+$ ]] && ((RPO_MINUTES > 0 && RPO_MINUTES <= 15)) ||
  die "RPO_MINUTES must be between 1 and 15"
[[ "$RTO_HOURS" =~ ^[0-9]+$ ]] && ((RTO_HOURS > 0 && RTO_HOURS <= 4)) ||
  die "RTO_HOURS must be between 1 and 4"

IFS=',' read -r -a databases <<<"$CLOUDSQL_DATABASES"
((${#databases[@]} > 0)) || die "CLOUDSQL_DATABASES must not be empty"
for database in "${databases[@]}"; do
  [[ "$database" =~ ^[A-Za-z_][A-Za-z0-9_-]{0,62}$ ]] ||
    die "Cloud SQL database name has an unsafe format"
done

uid_suffix="${POD_UID:-manual}"
uid_suffix="$(tr '[:upper:]' '[:lower:]' <<<"$uid_suffix" | tr -cd 'a-z0-9' | cut -c1-8)"
[[ -n "$uid_suffix" ]] || uid_suffix="unknown"
recovery_ts="$(date -u +%Y%m%dT%H%M%SZ)"
RECOVERY_ID="ar-${recovery_ts}-${uid_suffix}"
# VolumeSnapshot metadata.name must be DNS-1123; RECOVERY_ID keeps its
# uppercase T/Z for GCS paths and label values.
SNAPSHOT_PREFIX="vs-$(tr '[:upper:]' '[:lower:]' <<<"${recovery_ts}")"
ARCHIVE_PREFIX="${ARCHIVE_PREFIX:-recovery}"
ARCHIVE_PREFIX="${ARCHIVE_PREFIX#/}"
ARCHIVE_PREFIX="${ARCHIVE_PREFIX%/}"
[[ "$ARCHIVE_PREFIX" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]{0,126}$ ]] ||
  die "ARCHIVE_PREFIX has an unsafe format"
RECOVERY_URI="gs://${GCS_ARCHIVE_BUCKET}/${ARCHIVE_PREFIX}/${RECOVERY_ID}"

write_failure_evidence() {
  local rc=$1 completed_at
  completed_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  python3 - "$WORKDIR/failed.json" "$RECOVERY_ID" "$HELM_RELEASE" \
    "$STARTED_AT" "$completed_at" "$PHASE" "$rc" <<'PY'
import json
import sys

path, recovery_id, release, started, completed, phase, code = sys.argv[1:]
with open(path, "w", encoding="utf-8") as stream:
    json.dump(
        {
            "schemaVersion": 1,
            "recoveryId": recovery_id,
            "status": "FAIL",
            "providerStatus": "FAILED",
            "sourceRelease": release,
            "startedAt": started,
            "completedAt": completed,
            "failedPhase": phase,
            "exitCode": int(code),
            "artifactsComplete": False,
        },
        stream,
        sort_keys=True,
    )
    stream.write("\n")
PY
  gcloud storage cp "$WORKDIR/failed.json" \
    "${RECOVERY_URI}/evidence/FAILED.json" >/dev/null 2>&1 || true
}

cleanup() {
  local rc=$?
  trap - EXIT
  if ((rc != 0)) && [[ "$COMPLETE" != true ]]; then
    write_failure_evidence "$rc" || true
  fi
  rm -rf "$WORKDIR"
  exit "$rc"
}
trap cleanup EXIT

for command_name in gcloud kubectl python3; do
  command -v "$command_name" >/dev/null 2>&1 ||
    die "$command_name is required"
done

PHASE="archive-policy-preflight"
gcloud storage buckets describe "gs://${GCS_ARCHIVE_BUCKET}" --format=json \
  >"$WORKDIR/archive-bucket.json"
python3 - "$WORKDIR/archive-bucket.json" "$RETENTION_DAYS" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    bucket = json.load(stream)
minimum = int(sys.argv[2]) * 86400
retention = bucket.get("retentionPolicy") or bucket.get("retention_policy") or {}
locked = retention.get("isLocked", retention.get("is_locked", False))
period = retention.get("retentionPeriod", retention.get("retention_period", 0))
if isinstance(period, str):
    period = period.removesuffix("s")
uniform = bucket.get("uniformBucketLevelAccess")
if uniform is None:
    uniform = bucket.get("uniform_bucket_level_access", False)
if isinstance(uniform, dict):
    uniform = uniform.get("enabled", False)
pap = bucket.get("publicAccessPrevention")
if pap is None:
    pap = bucket.get("public_access_prevention", "")
if locked is not True:
    raise SystemExit("archive bucket retention policy is not locked")
if int(period) < minimum:
    raise SystemExit("archive bucket retention period is shorter than policy")
if uniform is not True:
    raise SystemExit("archive bucket does not enforce uniform bucket-level access")
if str(pap).lower() != "enforced":
    raise SystemExit("archive bucket does not enforce public access prevention")
PY

if gcloud storage ls "${RECOVERY_URI}/**" >/dev/null 2>&1; then
  die "recovery ID collision in immutable archive"
fi

PHASE="cloudsql-preflight"
gcloud sql instances describe "$CLOUDSQL_INSTANCE" \
  --project="$PROJECT_ID" --format=json >"$WORKDIR/cloudsql-instance.json"
python3 - "$WORKDIR/cloudsql-instance.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    instance = json.load(stream)
configuration = instance.get("settings", {}).get("backupConfiguration", {})
if configuration.get("enabled") is not True:
    raise SystemExit("Cloud SQL automated backups are disabled")
if configuration.get("pointInTimeRecoveryEnabled") is not True:
    raise SystemExit("Cloud SQL point-in-time recovery is disabled")
if instance.get("state") != "RUNNABLE":
    raise SystemExit("Cloud SQL instance is not RUNNABLE")
PY

PHASE="snapshot-policy-preflight"
kubectl get volumesnapshotclass.snapshot.storage.k8s.io "$SNAPSHOT_CLASS" \
  -o json >"$WORKDIR/snapshot-class.json"
python3 - "$WORKDIR/snapshot-class.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    snapshot_class = json.load(stream)
if snapshot_class.get("deletionPolicy") != "Retain":
    raise SystemExit("VolumeSnapshotClass deletionPolicy must be Retain")
if not snapshot_class.get("driver"):
    raise SystemExit("VolumeSnapshotClass driver is missing")
PY

for component in relaycast relayauth; do
  pvc_var="$(tr '[:lower:]' '[:upper:]' <<<"${component}")_PVC"
  pvc="${!pvc_var}"
  kubectl --namespace "$KUBERNETES_NAMESPACE" get pvc "$pvc" \
    -o json >"$WORKDIR/${component}-pvc.json"
  python3 - "$WORKDIR/${component}-pvc.json" "$pvc" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    pvc = json.load(stream)
if pvc.get("metadata", {}).get("name") != sys.argv[2]:
    raise SystemExit("PVC identity mismatch")
if pvc.get("status", {}).get("phase") != "Bound":
    raise SystemExit("PVC is not Bound")
PY
done

PHASE="pvc-snapshots"
for component in relaycast relayauth; do
  pvc_var="$(tr '[:lower:]' '[:upper:]' <<<"${component}")_PVC"
  pvc="${!pvc_var}"
  snapshot="${SNAPSHOT_PREFIX}-${component}"
  python3 - "$WORKDIR/${component}-snapshot-create.json" \
    "$snapshot" "$KUBERNETES_NAMESPACE" "$SNAPSHOT_CLASS" "$pvc" \
    "$RECOVERY_ID" "$HELM_RELEASE" <<'PY'
import json
import sys

path, name, namespace, snapshot_class, pvc, recovery_id, release = sys.argv[1:]
manifest = {
    "apiVersion": "snapshot.storage.k8s.io/v1",
    "kind": "VolumeSnapshot",
    "metadata": {
        "name": name,
        "namespace": namespace,
        "labels": {
            "app.kubernetes.io/instance": release,
            "app.kubernetes.io/managed-by": "agent-relay-recovery",
            "recovery-id": recovery_id,
            "recovery-component": name.rsplit("-", 1)[-1],
        },
    },
    "spec": {
        "volumeSnapshotClassName": snapshot_class,
        "source": {"persistentVolumeClaimName": pvc},
    },
}
with open(path, "w", encoding="utf-8") as stream:
    json.dump(manifest, stream)
PY
  kubectl create -f "$WORKDIR/${component}-snapshot-create.json" >/dev/null
  kubectl --namespace "$KUBERNETES_NAMESPACE" wait \
    --for=jsonpath='{.status.readyToUse}'=true \
    "volumesnapshot/${snapshot}" --timeout="${SNAPSHOT_TIMEOUT:-10m}" >/dev/null
  kubectl --namespace "$KUBERNETES_NAMESPACE" get volumesnapshot "$snapshot" \
    -o json >"$WORKDIR/${component}-snapshot.json"
  content="$(
    python3 - "$WORKDIR/${component}-snapshot.json" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as stream:
    snapshot = json.load(stream)
status = snapshot.get("status", {})
if status.get("readyToUse") is not True:
    raise SystemExit("snapshot is not ready to use")
content = status.get("boundVolumeSnapshotContentName")
if not content:
    raise SystemExit("snapshot has no bound content")
print(content)
PY
  )"
  kubectl get volumesnapshotcontent.snapshot.storage.k8s.io "$content" \
    -o json >"$WORKDIR/${component}-snapshot-content.json"
  python3 - "$WORKDIR/${component}-snapshot-content.json" \
    "$SNAPSHOT_CLASS" "$RECOVERY_ID" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as stream:
    content = json.load(stream)
if content.get("spec", {}).get("deletionPolicy") != "Retain":
    raise SystemExit("bound VolumeSnapshotContent deletionPolicy is not Retain")
if content.get("spec", {}).get("volumeSnapshotClassName") != sys.argv[2]:
    raise SystemExit("bound VolumeSnapshotContent class mismatch")
if not content.get("status", {}).get("snapshotHandle"):
    raise SystemExit("bound VolumeSnapshotContent has no snapshot handle")
PY
done

PHASE="cloudsql-backup"
gcloud sql backups create --instance="$CLOUDSQL_INSTANCE" \
  --project="$PROJECT_ID" --description="$RECOVERY_ID" --quiet >/dev/null
gcloud sql backups list --instance="$CLOUDSQL_INSTANCE" \
  --project="$PROJECT_ID" --filter="description=${RECOVERY_ID}" \
  --format=json >"$WORKDIR/cloudsql-backups.json"
python3 - "$WORKDIR/cloudsql-backups.json" "$RECOVERY_ID" \
  >"$WORKDIR/cloudsql-backup-id" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as stream:
    backups = json.load(stream)
matches = [
    backup for backup in backups
    if backup.get("description") == sys.argv[2]
    and backup.get("status") == "SUCCESSFUL"
    and backup.get("id") is not None
]
if len(matches) != 1:
    raise SystemExit("expected exactly one successful Cloud SQL backup")
print(matches[0]["id"])
PY

PHASE="cloudsql-immutable-exports"
: >"$WORKDIR/cloudsql-exports.txt"
for database in "${databases[@]}"; do
  uri="${RECOVERY_URI}/cloudsql/${database}.sql.gz"
  gcloud sql export sql "$CLOUDSQL_INSTANCE" "$uri" \
    --project="$PROJECT_ID" --database="$database" --quiet >/dev/null
  printf '%s\t%s\n' "$database" "$uri" >>"$WORKDIR/cloudsql-exports.txt"
done

PHASE="gcs-copy"
gcloud storage rsync --recursive "gs://${GCS_SOURCE_BUCKET}" \
  "${RECOVERY_URI}/gcs" >/dev/null

PHASE="evidence"
COMPLETED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
python3 - "$WORKDIR/backup.json" "$WORKDIR/cloudsql-backup-id" \
  "$WORKDIR/cloudsql-exports.txt" "$WORKDIR/relaycast-snapshot.json" \
  "$WORKDIR/relaycast-snapshot-content.json" \
  "$WORKDIR/relayauth-snapshot.json" \
  "$WORKDIR/relayauth-snapshot-content.json" \
  "$RECOVERY_ID" "$HELM_RELEASE" "$STARTED_AT" "$COMPLETED_AT" \
  "$PROJECT_ID" "$CLOUDSQL_INSTANCE" "$GCS_SOURCE_BUCKET" \
  "$GCS_ARCHIVE_BUCKET" "$ARCHIVE_PREFIX" "$RETENTION_DAYS" \
  "$RPO_MINUTES" "$RTO_HOURS" <<'PY'
import json
import sys

(
    output,
    backup_id_path,
    exports_path,
    relaycast_snapshot_path,
    relaycast_content_path,
    relayauth_snapshot_path,
    relayauth_content_path,
    recovery_id,
    release,
    started,
    completed,
    project,
    instance,
    source_bucket,
    archive_bucket,
    archive_prefix,
    retention_days,
    rpo_minutes,
    rto_hours,
) = sys.argv[1:]

def load(path):
    with open(path, encoding="utf-8") as stream:
        return json.load(stream)

def snapshot_evidence(snapshot_path, content_path):
    snapshot = load(snapshot_path)
    content = load(content_path)
    return {
        "name": snapshot["metadata"]["name"],
        "pvc": snapshot["spec"]["source"]["persistentVolumeClaimName"],
        "contentName": snapshot["status"]["boundVolumeSnapshotContentName"],
        "snapshotHandle": content["status"]["snapshotHandle"],
        "driver": content["spec"]["driver"],
        "deletionPolicy": content["spec"]["deletionPolicy"],
        "readyToUse": snapshot["status"]["readyToUse"],
    }

with open(backup_id_path, encoding="utf-8") as stream:
    backup_id = stream.read().strip()
exports = []
with open(exports_path, encoding="utf-8") as stream:
    for line in stream:
        database, uri = line.rstrip("\n").split("\t", 1)
        exports.append({"database": database, "uri": uri})

prefix = f"gs://{archive_bucket}/{archive_prefix}/{recovery_id}"
evidence = {
    "schemaVersion": 1,
    "recoveryId": recovery_id,
    "status": "PASS",
    "providerStatus": "SUCCESSFUL",
    "sourceRelease": release,
    "sourceProject": project,
    "startedAt": started,
    "completedAt": completed,
    "writesQuiesced": False,
    "consistency": "crash-consistent",
    "artifactsComplete": True,
    "policy": {
        "rpoMinutes": int(rpo_minutes),
        "rtoHours": int(rto_hours),
        "retentionDays": int(retention_days),
    },
    "immutableArchive": {
        "bucket": archive_bucket,
        "prefix": prefix,
        "retentionPolicyLocked": True,
    },
    "cloudSql": {
        "instance": instance,
        "backupId": backup_id,
        "immutableExports": exports,
    },
    "pvcSnapshots": {
        "relaycast": snapshot_evidence(relaycast_snapshot_path, relaycast_content_path),
        "relayauth": snapshot_evidence(relayauth_snapshot_path, relayauth_content_path),
    },
    "gcs": {
        "sourceBucket": source_bucket,
        "archiveUri": f"{prefix}/gcs",
    },
}
with open(output, "w", encoding="utf-8") as stream:
    json.dump(evidence, stream, indent=2, sort_keys=True)
    stream.write("\n")
PY

gcloud storage cp "$WORKDIR/backup.json" \
  "${RECOVERY_URI}/evidence/backup.json" >/dev/null
printf '%s\n' "$RECOVERY_ID" >"$WORKDIR/COMPLETE"
gcloud storage cp "$WORKDIR/COMPLETE" "${RECOVERY_URI}/COMPLETE" >/dev/null

COMPLETE=true
printf 'RECOVERY_RESULT=PASS recovery_id=%s evidence=%s\n' \
  "$RECOVERY_ID" "${RECOVERY_URI}/evidence/backup.json"
