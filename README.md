# AgentWorkforce Helm Charts

Single Helm chart repository for all AgentWorkforce services. Each service lives under `charts/<service-name>/`.

## Charts

| Chart | Description |
|-------|-------------|
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
kubectl -n 96bulls create secret generic 96bulls-locker \
  --from-literal=rootUser=<user> --from-literal=rootPassword=<password>
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

### Install the 96Bulls app charts individually

Both charts are hook-free, so `helm install` and Alchemy's
`helm template --no-hooks` + server-side apply behave the same. Create a
Secret with `HOOPDB_URL`, `LOCKER_ACCESS_KEY_ID` and `LOCKER_SECRET_ACCESS_KEY`
first (or enable `externalSecrets`).

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
