# AgentWorkforce Helm Charts

Single Helm chart repository for all AgentWorkforce services. Each service lives under `charts/<service-name>/`.

## Charts

| Chart | Description |
|-------|-------------|
| [relaycast](charts/relaycast) | Portable self-hosted Relaycast core — realtime agent communication with single-writer SQLite persistence |
| [relayfile](charts/relayfile) | Relayfile server — single Go binary, HTTP on :8080, Postgres-backed in production |
| [relayflows](charts/relayflows) | Durable workflows running locally in Kubernetes, with optional Cloud assignment mode |
| [96bulls-worker](charts/96bulls-worker) | 96Bulls sessions pipeline: HoopDb migrations, Locker bucket init, and the indexer/referee/bob-costas stage workers |
| [96bulls](charts/96bulls) | The whole 96Bulls pipeline in one release: 96bulls-worker + alleyoop, with optional HoopDb (CloudNativePG), Locker (MinIO) and an OTel collector |
| [alleyoop](charts/alleyoop) | 96Bulls ingest: receives session manifests and chunks and lands them in the Locker (S3) |
| [relayauth](charts/relayauth) | Self-hosted RelayAuth issuer: immutable image, externally managed keys, single-writer SQLite, and optional JWKS ingress |

## Quick start

```bash
helm repo add agentworkforce https://AgentWorkforce.github.io/helm-charts
helm repo update
```

### Install the Relaycast core

Relaycast is the minimal self-hosted core. Relayflows and 96Bulls are optional
add-ons and are not installed with it:

```bash
kubectl create namespace relaycast
kubectl -n relaycast create secret generic relaycast-secrets \
  --from-literal=internal-secret="$(openssl rand -hex 32)" \
  --from-literal=workspace-bootstrap-secret="$(openssl rand -hex 32)"
helm install relaycast agentworkforce/relaycast -n relaycast \
  --set baseUrl=https://relay.example.com \
  --set existingSecret=relaycast-secrets
```

Anonymous workspace creation is off; see
[charts/relaycast/README.md](charts/relaycast/README.md) for the first-run
workspace bootstrap, ingress, backups and restore, and upgrading from 0.1.0. The staged AWS-first/GCP-second adapter
plan and its proof gates are in
[docs/self-hosted-reference-architecture.md](docs/self-hosted-reference-architecture.md).
That document also records the transcript search decision: PostgreSQL 17 with
`pg_trgm` is the default backend (`postgres`). ClickHouse OSS is an optional
scale profile and is not charted yet.

### Install relayfile

```bash
helm install relayfile agentworkforce/relayfile \
  --set secrets.internalHmacSecret=<strong-secret> \
  --set secrets.productionDsn='postgres://user:pass@host:5432/dbname?sslmode=require' \
  --set auth.jwksUrl=https://auth.relay.example.com/.well-known/jwks.json
```

See [charts/relayfile/README.md](charts/relayfile/README.md) for the full parameter reference.

### Run Relayflows locally

Bundle a flow, the Relayflows runtime CLI, and its harness CLIs into an image,
then run it as a Kubernetes Job. This default mode does not use Agent Relay
Cloud:

```bash
helm install relayflows agentworkforce/relayflows \
  --namespace relayflows --create-namespace \
  --set image.repository=registry.example.com/acme/my-flow \
  --set image.tag=sha-0123456789abcdef \
  --set runtimeInstaller.enabled=false \
  --set standalone.flow.path=/app/flows/customer.flow.ts
```

See [charts/relayflows/README.md](charts/relayflows/README.md) for ConfigMap
flows, model credentials, resuming runs, and optional Cloud worker mode.

### Install the 96Bulls pipeline (umbrella)

One release runs everything. Prerequisite: the CloudNativePG operator (see
[`deps/PINS.md`](deps/PINS.md)). Then create one Secret and install:

```bash
kubectl create namespace 96bulls
read -rsp 'SUMMARY_MASTER_KEYS (<key-id>:<64-hex>): ' SUMMARY_MASTER_KEYS; printf '\n'
printf %s "$SUMMARY_MASTER_KEYS" | kubectl -n 96bulls create secret generic 96bulls-locker \
  --from-literal=rootUser=<user> \
  --from-literal=rootPassword=<password> \
  --from-file=SUMMARY_MASTER_KEYS=/dev/stdin
unset SUMMARY_MASTER_KEYS
helm install bulls agentworkforce/96bulls -n 96bulls \
  --set global.tenant.orgId=<org> \
  --set alleyoop.auth.jwksUrl=https://<relayauth>/.well-known/jwks.json
```

The charts default to `ghcr.io/agentworkforce/96bulls-services`, pinned by
digest. That hosted-service package is private. For direct installs, create a
docker-registry Secret and add `--set worker.imagePullSecrets[0].name=<secret>
--set alleyoop.imagePullSecrets[0].name=<secret>`. When overriding either app's
image repository or tag, also clear its shipped digest with
`--set worker.image.digest= --set alleyoop.image.digest=` (or supply matching
digests). Hosted EKS installs instead set both `worker.image.repository` and
`alleyoop.image.repository` to the fully qualified ECR repository plus its
matching digest; EKS nodes authenticate through their node role, so that path
does not need an image pull Secret. The OpenTelemetry collector is off by default; set
`global.otel.endpoint` to your backend, or set both `otel.enabled=true` and
`global.otel.endpoint=http://otel-collector:4318` to use the bundled collector.
Its safe default exporter drops telemetry; replace `otel.config.exporters` and
the pipeline exporters with your backend configuration outside local testing.

Bob Costas reads `SUMMARY_MASTER_KEYS` from a Secret and stores only encrypted
summary objects in the Locker; no key value belongs in Helm values. The worker
chart projects that Secret key as a read-only file into Bob Costas only. Set
`worker.summaryEncryption.existingSecret` when the key is not in the shared
Secret (required for pod-identity installs with no `worker.existingSecret`).

HoopDb credentials come from the Secret CloudNativePG generates
(`hoopdb-app`). Bring your own Postgres or S3 by disabling `hoopdb` or
`locker` and pointing `worker.*` / `alleyoop.*` at your infrastructure. On EKS,
set both app charts' `locker.credentials.mode=podIdentity` to omit
`LOCKER_ACCESS_KEY_ID` and `LOCKER_SECRET_ACCESS_KEY`; the AWS SDK then uses its
workload identity credential chain. Leave `locker.endpoint` empty to use the
native AWS S3 endpoint for `locker.region`. Unless the cluster uses EKS Auto
Mode, first install the
[EKS Pod Identity Agent](https://docs.aws.amazon.com/eks/latest/userguide/pod-id-agent-setup.html).
Create the IAM associations for the rendered worker and alleyoop
ServiceAccounts before deploying the workloads, because EKS injects the Pod
Identity configuration when each Pod starts. If associations are added later,
restart the app Pods and recreate any failed locker-init Job. If the S3 bucket
is already created and versioned, also set `worker.lockerInit.enabled=false`;
otherwise the worker role needs permission to create the bucket and enable
versioning.
`ci/96bulls-umbrella/smoke.sh` runs the umbrella on kind.

#### Profiles and the HoopDb migration contract

`worker.migrations` carries the migrator's database profile: 96BullSessions
`src/hoopdb/migrate.ts` `migrationProfile()` at main
`b47c1e6af43140de8395c1aa20178d014c92bbb7` (#99 plus the #106 Supabase
compatibility change). Each value is rendered at most
once, as an env var in the migrate container only. The render refuses these
names in `worker.extraEnv` and component `env`, along with
`HOOPDB_ROLE_BOOTSTRAP` and the old `HOOPDB_FUNCTION_BOUNDARY_APPROVED` name.
Where the migrator has no default, neither does the chart:

| value | env | rule |
| --- | --- | --- |
| `databaseMode` | `HOOPDB_DB_MODE` | Required: `local`, `selfhosted`, `cloudsql` (Google Cloud SQL) or `supabase`. |
| `supabaseShim` | `HOOPDB_SUPABASE_SHIM` | Required in local, selfhosted and cloudsql. In supabase mode it must be unset or false, and it is rendered `false`. |
| `roleBootstrap` | `HOOPDB_ROLE_BOOTSTRAP` | Optional (the migrator defaults it to the shim choice). Refused as true in supabase. Cloud SQL sets false. |
| `runtimeRole` | `HOOPDB_RUNTIME_ROLE` | Required. Outside local mode it must be a dedicated role, never the migration owner or the search Worker. |
| `runtimeRoleLogin` | `HOOPDB_RUNTIME_ROLE_LOGIN` | Required outside local mode; rendered only when set. |
| `runtimeWorkloadRole` | `HOOPDB_RUNTIME_WORKLOAD_ROLE` | Optional. |
| `functionBoundaryMode` | `HOOPDB_FUNCTION_BOUNDARY_MODE` | `global-default-revoke` is the only implemented mode; `event-trigger` is refused. Required in selfhosted and cloudsql. In supabase it is the operator's decision (96BullSessions #98); unset, migrate fails closed. |

`charts/96bulls/profiles/` ships four render shapes:

- `selfhost-postgres.yaml`: a new install on the in-cluster CNPG HoopDb, in
  selfhosted mode. initdb creates the search Worker role. Before migrate, two
  privileged Jobs run as `postgres` on every deploy:
  - `runtimeRole.bootstrapJob` runs `hoopdb_runtime_role.sql`. It creates or
    verifies the runtime role, revokes TEMPORARY from PUBLIC on the database
    (a database-wide change) and grants the role CONNECT.
  - `functionDefaultRevoke.bootstrapJob` runs
    `hoopdb_function_default_revoke.sql`. It sets the global function default
    of the owner and every superuser to `{<self>:EXECUTE}` and refuses a
    poisoned default (55000).

  migrate's `wait-for-role` waits for both roles and for the owner's exact
  function default.
- `migration.yaml`: an existing in-cluster CNPG HoopDb from before the search
  Worker role existed. It is `selfhost-postgres.yaml` plus
  `searchWorkerRole.bootstrapJob`.
- `external-selfhosted.yaml`: an external operator-controlled plain-Postgres
  HoopDb (RDS, your own Postgres) in selfhosted mode. There are no in-cluster
  SQL Jobs, and migrate waits for the roles. The operator runs the three
  bootstrap files as a superuser. Google Cloud SQL uses `cloudsql` mode instead:
  see `charts/96bulls/ci/gcp-cloudsql-values.yaml`. There the shim is off,
  `roleBootstrap` is false, the migration-owner URL is separate, and the
  operator runs the Cloud SQL bootstrap files.
- `external-supabase.yaml`: an external Supabase project in supabase mode. It
  has no shim, no wait-for-role and no in-cluster SQL Jobs, and the chart
  refuses each of those in supabase mode. Never run
  `hoopdb_function_default_revoke.sql` on Supabase. The runtime role is
  `bulls96_runtime` with LOGIN and no workload role. Do not use the drifted
  legacy `relayhistory_runtime`. The Worker role is
  `session_directory_search_worker`.

  The profile pins the b47c1e6 GHCR image, which includes #106, but it is
  still **fail-closed** in two ways. `supabaseActivation.hold` stops it from
  rendering, and `functionBoundaryMode` is unset (an operator decision,
  96BullSessions #98). Lift the hold only once that image is confirmed as the
  production-Supabase pin. The operator prerequisites are listed in the
  profile, including the Supabase-only bootstrap wrappers.

Every profile, every CI values file, and the worker and alleyoop chart
defaults pin the services image built from 96BullSessions main `b47c1e6`, GHCR
`ghcr.io/agentworkforce/96bulls-services@sha256:e48d62dacc6dd6c0d0f912656693bb4a937c1f0d14562afa273601ea1ba0463a`
(publish-image run 41333160108). Its migration generation is
`1d99ccc8222995c9f8c31334da1c574ca5a687436656d34d9521bc7859494718`. The AWS
proof values (`charts/96bulls/ci/aws-cnpg-values.yaml`) pin the immutable ECR
digest from the same source,
`500268966557.dkr.ecr.us-west-2.amazonaws.com/96bulls-services@sha256:5fb1cc209c9f0398ee0c9cf3cf050335f2388241df1b307538e915ca76f3c698`
(publish-image-ecr run 41333164245). Every profile
also needs `global.tenant.orgId` and `alleyoop.auth.jwksUrl`.

`ci/96bulls-profiles/matrix.sh` renders every profile and every
`charts/96bulls/ci/*-values.yaml`. Those include the AWS CNPG proof, AWS
external Supabase (`pod-identity`) and GCP Cloud SQL. For each one it asserts:
- the workloads and migrate, with phase 2 verify;
- the exact profile env, in migrate only;
- HoopDb and Locker;
- which privileged Jobs render, with their psql variables and files;
- what migrate waits for;
- the image pins: every row renders only the final images, and the ECR image only on the AWS path.

It also checks every mode combination the chart must refuse. CI runs it
offline (`static`) and as a server-side dry run on kind (`dryrun`).
`ci/96bulls-search-worker-role/kind.sh` builds the services image from
`services-commit` (b47c1e6) and fails unless the image's generation equals
`services-generation`.

#### Session directory search Worker role

HoopDb's session directory migration only *verifies* the role
`session_directory_search_worker` (`NOLOGIN NOINHERIT NOBYPASSRLS NOSUPERUSER
NOCREATEDB NOCREATEROLE NOREPLICATION`, exactly `statement_timeout=2s`, no
memberships). Creating it needs a superuser on PostgreSQL 16+, so the chart
provisions it (96BullSessions `runbooks/session-directory-search-worker-bootstrap.md`):

- **New clusters:** two `hoopdb.cluster.initdb.postInitApplicationSQL` statements,
  run once by CNPG as `postgres`. Remove them to opt out.
- **Existing clusters:** `searchWorkerRole.bootstrapJob.enabled=true` with
  `sqlImage` set to the services image by digest. A separate Job (its own
  ServiceAccount; a Role limited to `pods` get/list and `pods/exec`) runs the
  image's `supabase/bootstrap/session_directory_search_worker.sql` as `postgres`
  by `kubectl exec` into the primary. `enableSuperuserAccess` stays false. It is
  idempotent and never alters a role that differs from the spec (it fails with
  `55000`). The sql init container, which runs the services image, gets no API
  token: the pod has `automountServiceAccountToken: false` and only the kubectl
  container mounts a projected token. Pull auth is `worker.imagePullSecrets`
  (the umbrella's shared `imagePullSecrets`), the same Secret as the workloads.
- **Order** (no Helm hooks): the migrate Job's `wait-for-role` init container
  (`worker.migrations.waitForRole`, on by default in the umbrella, on the pinned
  HoopDb image) polls HoopDb until the role exists, so bootstrap and migrate are
  applied together. migrate then verifies the role (phase 1), migrates, and
  checks its grants (phase 2) and records PASS for the image's migration
  generation in `sessions.__96bulls_role_validation`. Workloads are ready only
  while that PASS is current, so a phase 2 failure after the ledger is
  complete leaves everything unready. migrate always sets
  `HOOPDB_ROLE_VERIFY=true`, and `worker.extraEnv` may not override it: with
  verify off, readiness would need a separate mark_pass step, which this chart
  does not run. A drifted role fails both Jobs with `55000` and nothing
  becomes ready.
- **Disabling** the Job removes the Job and its RBAC; the role is never dropped
  (see the runbook's "Rollback and removal").

`ci/96bulls-search-worker-role/render.sh` asserts the rendered objects;
`ci/96bulls-search-worker-role/kind.sh` (required in CI) runs on the real
services image, which CI builds from the 96BullSessions commit in
`ci/96bulls-search-worker-role/services-commit` (the published image is
private; locally, pass `SERVICES_IMAGE`). It proves:
- a fresh and an existing CNPG cluster converge to the same role;
- a drifted role is refused with `55000` (exit 3);
- in the whole release, migrate waits while the bootstrap is held back and no
  workload is ready; after the bootstrap, migrate passes both role checks and
  the workloads become ready;
- a phase-2-only failure after the ledger is complete (a direct grant) sets the
  role validation marker to pending, and running and restarted workloads go
  unready;
- with a drifted role, both Jobs fail with `55000` and nothing becomes ready.

#### Transcript search profiles

The default transcript search profile is the HoopDb Postgres with `pg_trgm`
(backend `postgres`); self-managed ClickHouse OSS is an optional derived index
for high-volume installs. No chart exposes a `search.*` value yet. See
[Transcript search profiles](docs/self-hosted-reference-architecture.md#transcript-search-profiles)
for the decision and the planned values/Secret boundary.

#### Transcript search profiles

Shared transcript search has two profiles, written in
[docs/self-hosted-reference-architecture.md](docs/self-hosted-reference-architecture.md).
The default backend is `postgres`: PostgreSQL 17 and `pg_trgm` on the HoopDb
this chart already installs. The search Worker role above is the privilege
boundary for that path. ClickHouse OSS is the optional high-volume index.
Nothing in this repository reads a ClickHouse value, and core availability
does not depend on it. `neon` is a hosted-provider name, not the self-hosted
search backend. `HOOPDB_DB_MODE=selfhosted` is unchanged.

### Install the 96Bulls app charts individually

Both charts are hook-free, so `helm install` and Alchemy's
`helm template --no-hooks` + server-side apply behave the same. Create a
Secret with `HOOPDB_URL`, `LOCKER_ACCESS_KEY_ID`,
`LOCKER_SECRET_ACCESS_KEY` and `SUMMARY_MASTER_KEYS` first (or enable
`externalSecrets`). `SUMMARY_MASTER_KEYS` is referenced only by Bob Costas.

For workload identity, set `locker.credentials.mode=podIdentity` and provide
`hoopdb.existingSecret`; `existingSecret` may then be empty. This suppresses
both static Locker credential environment variables in every workload and in
the worker's locker-init Job. `locker.endpoint` may also be empty to select the
native AWS S3 endpoint.

> The default image `ghcr.io/agentworkforce/96bulls-services` (pinned by
> digest) is private: add `--set imagePullSecrets[0].name=<secret>` to both
> commands. If you override `image.repository` or
> `image.tag`, also set `image.digest=` or supply the matching digest.


```bash
helm install bulls agentworkforce/96bulls-worker -n 96bulls --create-namespace \
  --set existingSecret=96bulls \
  --set locker.endpoint=http://locker:9000 \
  --set tenant.orgId=<org>
helm install alleyoop agentworkforce/alleyoop -n 96bulls \
  --set existingSecret=96bulls \
  --set locker.endpoint=http://locker:9000 \
  --set tenant.orgId=<org> \
  --set auth.jwksUrl=https://<relayauth>/.well-known/jwks.json
```

`ci/96bulls/smoke.sh` runs the whole pipeline on kind, with CloudNativePG
(Postgres 17), MinIO and an OpenTelemetry collector. Third-party charts and
images are pinned once, in [`deps/`](deps/PINS.md).

## Releases

Charts are packaged and published to GitHub Pages via [helm/chart-releaser-action](https://github.com/helm/chart-releaser-action) on every merge to `main`, after the same lint checks that run on pull requests pass. chart-releaser detects changed chart versions automatically — each service chart is released independently.

Each released chart is also pushed to GHCR as an OCI artifact:

```bash
helm install <release> oci://ghcr.io/agentworkforce/charts/<chart> --version <version>
```

## Contributing

Add new service charts under `charts/<service-name>/`. Open a PR against `main`. Merges are gated by Khaliq.

Every chart must install correctly through `helm template --no-hooks` plus server-side apply, which is how Alchemy's `Kubernetes.HelmChart` installs it. Pull requests run `.github/workflows/lint.yml`:

- `helm lint --strict`, once per `charts/<chart>/ci/*-values.yaml` (or with defaults when there are none).
- **No Helm hooks.** Hooks never run under `--no-hooks`; use a plain Job instead (see `96bulls-worker`).
- **Deterministic renders.** No `randAlphaNum`, `lookup` or `now`, or every render looks like drift.
- `kubeconform`, plus a server-side dry-run apply on kind.
- **A version bump** for any chart change outside `ci/`.

Run the same checks locally with `scripts/ci/charts.sh static` and `scripts/ci/charts.sh dryrun` (the dry run needs a cluster in the current kube context).
