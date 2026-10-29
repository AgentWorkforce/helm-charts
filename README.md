# AgentWorkforce Helm Charts

Single Helm chart repository for all AgentWorkforce services. Each service lives under `charts/<service-name>/`.

## Charts

| Chart | Description |
|-------|-------------|
| [relayfile](charts/relayfile) | Relayfile server — single Go binary, HTTP on :8080, Postgres-backed in production |
| [relayflows](charts/relayflows) | Durable workflows running locally in Kubernetes, with optional Cloud assignment mode |
| [96bulls-worker](charts/96bulls-worker) | 96Bulls sessions pipeline: HoopDb migrations, Locker bucket init, and the indexer/referee/bob-costas stage workers |
| [alleyoop](charts/alleyoop) | 96Bulls ingest: receives session manifests and chunks and lands them in the Locker (S3) |

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

### Install the 96Bulls pipeline

Both charts are hook-free, so `helm install` and Alchemy's
`helm template --no-hooks` + server-side apply behave the same. Create a
Secret with `HOOPDB_URL`, `LOCKER_ACCESS_KEY_ID` and `LOCKER_SECRET_ACCESS_KEY`
first (or enable `externalSecrets`).

> The default image `ghcr.io/agentworkforce/96bulls-services` is not published
> yet. Until it is, add `--set image.repository=<repo> --set image.tag=<tag>`
> to both commands (`ci/96bulls/smoke.sh` builds and loads one for kind).


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
