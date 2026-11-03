# GCP backup, restore, and rollback

This runbook covers the `agent-relay` `portable-single` suite:

- PostgreSQL databases for 96Bulls (`hoopdb`), RelayHistory, and the control
  API;
- Relaycast SQLite and uploaded files on its retained RWO PVC;
- RelayAuth SQLite on its retained RWO PVC;
- 96Bulls Locker objects in GCS.

A recovery set is valid only when all artifacts use one recovery ID and are
captured while application writes are stopped. Cloud SQL backups are
instance-wide; repeat the database steps when the databases use separate
instances.

## Safety rules

- Never restore directly over production during a drill.
- Restore into a separate Cloud SQL instance, GCS bucket, namespace, PVCs, and
  Helm release.
- Initially use the exact recorded chart version and immutable image digests.
- Keep credentials in the approved secret manager and out of evidence files.
- Do not run migrations or `helm upgrade` during capture or restore.
- Preserve the failed production state before rollback.
- Verify a recovery ID ownership label before deleting any temporary resource.
- Do not use Helm `--atomic` as a recovery control. Helm can change Kubernetes
  resources after a failed release, but it cannot reverse database migrations
  or restore PostgreSQL, SQLite, PVC, or GCS data.
- Do not automatically run `helm rollback`, uninstall, or retry a migration
  after failure. First identify which migrations and writes completed.

## Pre-upgrade recovery gate

Every upgrade that can run a database or data migration requires all of the
following before `helm upgrade`:

1. a migration compatibility review from the current chart and image versions
   to the exact target versions, classifying each migration as
   backward-compatible or forward-only;
2. a complete recovery set captured from the currently deployed Helm revision
   while writes are quiesced;
3. a successful isolated restore of that recovery set, including all
   verification gates below;
4. an approved database-aware recovery strategy: database restore or
   side-by-side restore and traffic cutover;
5. confirmation that no migration or backup Job is active or failed.

Record these as non-secret JSON evidence and run the read-only gate documented
in [`scripts/selfhost/README.md`](../scripts/selfhost/README.md):

```bash
scripts/selfhost/pre-upgrade-check.sh \
  --context "$(kubectl config current-context)" \
  --namespace "$PROD_NS" \
  --release "$RELEASE" \
  --target-chart ./charts/agent-relay \
  --backup-evidence "$EVIDENCE_DIR/backup.json" \
  --restore-evidence "$EVIDENCE_DIR/restore.json" \
  --compatibility-evidence "$EVIDENCE_DIR/compatibility.json"
```

A successful gate does not make a migration reversible and does not authorize
the upgrade. Keep the normal review and explicit mutation approval.

## Capture

Set environment-specific variables:

```bash
export PROJECT_ID="customer-project"
export REGION="us-central1"
export CLUSTER="customer-gke"
export PROD_NS="agent-relay"
export RELEASE="agent-relay"
export SQL_SOURCE="agent-relay-postgres"
export GCS_SOURCE="customer-session-locker"
export GCS_BACKUP="${PROJECT_ID}-agent-relay-backups"
export SNAPSHOT_CLASS="approved-retain-snapshot-class"
export RECOVERY_ID="ar-$(date -u +%Y%m%dT%H%M%SZ)"
export EVIDENCE_DIR="./evidence/${RECOVERY_ID}"

mkdir -p "$EVIDENCE_DIR"
gcloud config set project "$PROJECT_ID"
gcloud container clusters get-credentials "$CLUSTER" --region "$REGION"
```

Record Helm state and inventory without exporting credential values. Raw
`helm get values -a` and `helm get manifest` output is not safe evidence: an
inline `relayflows.credentials.enrollmentToken` appears in the computed values,
and the chart-managed Secret it renders appears in the manifest. Redact both
before writing anything to the evidence directory, and prefer
`relayflows.credentials.existingSecret` in any install that produces evidence:

```bash
helm history "$RELEASE" -n "$PROD_NS" -o json \
  > "$EVIDENCE_DIR/helm-history.json"
helm get values "$RELEASE" -n "$PROD_NS" -a -o yaml |
  yq 'del(.relayflows.credentials.enrollmentToken)' \
  > "$EVIDENCE_DIR/helm-values.yaml"
helm get manifest "$RELEASE" -n "$PROD_NS" |
  yq 'select(.kind != "Secret")' \
  > "$EVIDENCE_DIR/helm-manifest.yaml"
helm get manifest "$RELEASE" -n "$PROD_NS" | sha256sum \
  > "$EVIDENCE_DIR/helm-manifest.sha256"
kubectl -n "$PROD_NS" get deploy,statefulset,job,cronjob,pvc -o wide \
  > "$EVIDENCE_DIR/kubernetes-inventory.txt"
gcloud sql instances describe "$SQL_SOURCE" --format=json \
  > "$EVIDENCE_DIR/cloudsql-source.json"
gcloud storage buckets describe "gs://${GCS_SOURCE}" --format=json \
  > "$EVIDENCE_DIR/gcs-source.json"
```

Before keeping the evidence, confirm the redaction held:
`grep -n enrollmentToken "$EVIDENCE_DIR/helm-values.yaml"` must print nothing,
and the redacted manifest must contain no `kind: Secret` document. If either
check fails, delete the file and stop. Because the redacted values omit inline
credentials, a restore from `recorded-values.yaml` must supply them through an
`existingSecret` in the target namespace.

Confirm that no migration or backup Job is running; the three database URLs
select dedicated databases; both Relaycast and RelayAuth PVCs are `Bound`; the
snapshot class uses `deletionPolicy: Retain`; and GCS versioning and retention
match policy.

Capture non-secret canaries: workspace, agent, message, and session IDs;
per-database table counts; and GCS object count and bytes.

### 1. Quiesce writes

Enable maintenance mode at the public edge. Record replica counts, scale all
suite Deployments to zero, and confirm no writer remains:

```bash
kubectl -n "$PROD_NS" get deploy \
  -l "app.kubernetes.io/instance=${RELEASE}" -o json \
  > "$EVIDENCE_DIR/deployments-before.json"
kubectl -n "$PROD_NS" scale deploy \
  -l "app.kubernetes.io/instance=${RELEASE}" --replicas=0
```

### 2. Capture Cloud SQL

```bash
gcloud sql backups create \
  --instance="$SQL_SOURCE" \
  --description="$RECOVERY_ID"
gcloud sql backups list \
  --instance="$SQL_SOURCE" \
  --filter="description:${RECOVERY_ID}" \
  --sort-by="~endTime" --format=json \
  > "$EVIDENCE_DIR/cloudsql-backup.json"
```

Require a successful result and record the numeric backup ID.

### 3. Snapshot both retained PVCs

Discover claim names; do not infer them from the release name:

```bash
kubectl -n "$PROD_NS" get pvc \
  -o custom-columns=NAME:.metadata.name,APP:.metadata.labels.app\\.kubernetes\\.io/name
```

Create one retained `VolumeSnapshot` for Relaycast and one for RelayAuth:

```yaml
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshot
metadata:
  # VolumeSnapshot names must be lowercase DNS-1123; the recovery-id label
  # carries the mixed-case RECOVERY_ID used in GCS paths and evidence.
  name: vs-RECOVERY_ID_LOWER-relaycast
  namespace: PROD_NAMESPACE
  labels:
    recovery-id: RECOVERY_ID
    managed-by: agent-relay-recovery
spec:
  volumeSnapshotClassName: RETAIN_SNAPSHOT_CLASS
  source:
    persistentVolumeClaimName: RELAYCAST_PVC
```

Repeat for `RECOVERY_ID-relayauth` with the RelayAuth claim. Wait until both
have `status.readyToUse: true`, then record each bound
`VolumeSnapshotContent`, `snapshotHandle`, driver, and retention policy.

If Relaycast chart backups are enabled, retain a completed online backup as a
second recovery path. Only backup directories containing `COMPLETE` are valid.

### 4. Copy GCS

The backup bucket must use uniform access, public-access prevention, and the
approved retention policy.

```bash
gcloud storage rsync --recursive \
  "gs://${GCS_SOURCE}" \
  "gs://${GCS_BACKUP}/${RECOVERY_ID}/locker"
gcloud storage rsync --recursive --checksums-only --dry-run \
  "gs://${GCS_SOURCE}" \
  "gs://${GCS_BACKUP}/${RECOVERY_ID}/locker" \
  > "$EVIDENCE_DIR/gcs-rsync-verification.txt"
```

The dry run must require no copy or replacement. Preserve object names,
generations, sizes, and CRC32C values when required by policy.

### 5. Resume production

Restore recorded replica counts. Remove maintenance mode only after readiness,
ingress, messaging, ingest, search, and replay checks pass.

## Isolated restore drill

Create uniquely named target resources labeled with the recovery ID:

- separate namespace and Helm release;
- separate Cloud SQL instance restored from the selected backup;
- separate GCS bucket populated from the selected recovery prefix;
- separate Relaycast and RelayAuth PVCs created from imported snapshots;
- separate Kubernetes Secret objects populated through approved secret
  delivery.

The target must have no production ingress or DNS and no route to production
databases or buckets.

For cross-namespace CSI restore, create uniquely named pre-provisioned
`VolumeSnapshotContent` objects using the retained snapshot handles, import
them into target-namespace `VolumeSnapshot` objects, then create RWO PVCs.
Requested sizes must be at least the source sizes. Never bind source PVs or
PVCs into the target.

Install with an isolated overlay. The migration and Locker initialization Jobs
are plain Kubernetes Jobs, not Helm hooks, so `--no-hooks` does not stop them;
the overlay must disable them explicitly. The restored databases already carry
the recorded schema, and the restored bucket already exists:

- `relayhistory.migrations.enabled=false`;
- `relay-cloud-api.migrations.enabled=false`;
- `96bulls.worker.migrations.enabled=false`;
- `96bulls.worker.lockerInit.enabled=false`;
- `relaycast.backup.enabled=false`, so no backup CronJob writes during the
  drill;
- `gkeIngress.enabled=false` and all leaf ingresses disabled;
- `relaycast.persistence.existingClaim` set to the restored Relaycast PVC;
- `relayauth.persistence.existingClaim` set to the restored RelayAuth PVC;
- all database URLs pointing only to the restored instance;
- Locker bucket pointing only to the restored bucket;
- the recorded chart version and immutable image digests.

For example, `isolated-restore-overlay.yaml` starts with:

```yaml
gkeIngress:
  enabled: false
relayhistory:
  migrations:
    enabled: false
relay-cloud-api:
  migrations:
    enabled: false
96bulls:
  worker:
    migrations:
      enabled: false
    lockerInit:
      enabled: false
relaycast:
  backup:
    enabled: false
```

Render first and confirm the target manifest contains no `Job` objects before
installing:

```bash
helm template "$TARGET_RELEASE" ./charts/agent-relay \
  --namespace "$TARGET_NS" --no-hooks \
  -f recorded-values.yaml \
  -f isolated-restore-overlay.yaml |
  yq 'select(.kind == "Job" or .kind == "CronJob") | .metadata.name'
# must print nothing

helm install "$TARGET_RELEASE" ./charts/agent-relay \
  --namespace "$TARGET_NS" --create-namespace --no-hooks \
  -f recorded-values.yaml \
  -f isolated-restore-overlay.yaml \
  --wait --timeout 30m
```

## Verification gates

A restore passes only when:

- every target resource has the recovery ID and no target manifest or
  Workload Identity binding references production;
- all pods use the recorded immutable images;
- each PostgreSQL connection selects the expected dedicated database, roles
  retain runtime/migration separation, migrations match, and table counts are
  plausible;
- `PRAGMA integrity_check;` returns `ok` for both `relaycast.db` and
  `relayauth.db`;
- Relaycast contains the known workspace, agents, message, and files;
- GCS counts and bytes match, with matching CRC32C for approved samples;
- an isolated two-agent ping and reply succeeds;
- the known session can be found and replayed;
- identical delivery retry remains idempotent; and
- cross-workspace access is denied.

Record commands, timestamps, results, and operator approval without tokens,
password-bearing URLs, private keys, or Secret values.

## Recovery and cleanup

Prefer side-by-side recovery: block writes, preserve a forensic backup of the
failed state, restore one complete recovery set into new resources, pass every
gate, and switch traffic only after approval. Never mix recovery IDs.

Helm rollback restores release-managed Kubernetes manifests; it does not undo
PostgreSQL or SQLite schema changes, reverse transformed or deleted rows, or
restore PVC and GCS contents. Use `helm rollback` only when reviewed
compatibility evidence proves the previous application can safely run against
the post-migration data. Even then, the database remains migrated.

For a forward-only or uncertain migration, restore the pre-upgrade Cloud SQL
backup, both matching PVC snapshots, and the matching GCS recovery prefix into
isolated resources. Install the recorded chart and immutable image versions,
verify them, and cut over only after approval. Never restore only one data
store from a recovery set.

Cleanup applies only to isolated targets. Before deletion, assert each
resource's `recovery-id` label equals the selected recovery ID. If any check
fails, stop. Never delete production databases, buckets, PVCs, retained
snapshots, recovery prefixes, or secret-manager versions as part of drill
cleanup.
