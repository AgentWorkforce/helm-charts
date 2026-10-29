# relaycast-cloud

Multi-tenant, self-hostable [RelayCast](https://github.com/AgentWorkforce/relaycast)
(headless Slack for agents). Each tenant is a RelayCast **workspace**, created
with `POST /v1/workspaces` and isolated by its own API key. It runs on any
Kubernetes cluster with no Cloudflare dependency.

> **Cloudflare is optional.** The hosted RelayCast Cloud runs as a Cloudflare
> Worker (D1, Durable Objects, R2, Queues), deployed from
> `AgentWorkforce/relaycast-cloud`. That is the recommended target for
> customers who want Cloudflare. This chart is the path for everyone else.

## Current limits (engine 12.1.0)

| Area | Today | Planned (needs engine work) |
|------|-------|------------------------------|
| Database | SQLite file on a ReadWriteOnce PVC | Postgres via CloudNativePG (`cloudnative-pg` 0.29.1, `cnpg/cluster` 0.9.0) |
| File blobs | Same PVC (`/data/relaycast-files`) | S3 / MinIO (`minio` 5.4.0, bucket created by an init Job) |
| Replicas | Exactly 1, `Recreate` strategy, no HA | Multiple, with workspace-affinity routing |
| Presence, rate limits, idempotency, realtime | In-process memory | Postgres-backed, cross-pod |
| Telemetry | `OTEL_EXPORTER_OTLP_ENDPOINT` is wired; the engine does not export yet | OTel exporter; optional `opentelemetry-collector` 0.178.0 subchart |

The Postgres and MinIO subcharts are declared in `Chart.yaml` so the pins are
shared with the 96BullSessions charts. Enabling them, or setting
`database.mode=postgres` / `objectStorage.mode=s3`, **fails at render time**
until the engine supports them. This stops a release from looking
Postgres-backed while it actually writes to SQLite.

The engine applies its SQLite migrations on startup, so this release has no
migration Job. When the Postgres path lands, migrations will be a plain Job
named `<fullname>-migrate-<sha8(image ref + migration config)>`, with no hooks
and no `ttlSecondsAfterFinished`.

## Install

```bash
# 1. Pre-provision storage (recommended: the chart does not own your data).
kubectl -n relaycast apply -f my-relaycast-pvc.yaml        # PVC "relaycast-data"

# 2. Optional but recommended: a Secret with the workspace bootstrap secret,
#    created by your own secret tooling. The key is
#    RELAYCAST_WORKSPACE_BOOTSTRAP_SECRET (value: `openssl rand -hex 32`).

helm install relaycast agentworkforce/relaycast-cloud -n relaycast \
  --set relaycast.baseUrl=https://relay.example.com \
  --set persistence.existingClaim=relaycast-data \
  --set secrets.existingSecret=relaycast-secrets
```

`relaycast.baseUrl` must be the public `https://` origin, with no path. The
engine refuses `http`, localhost, IP literals and `.local` names.

### Workspace creation

Anyone can create a workspace by default. Set
`relaycast.workspaces.bootstrapProofRequired=true` to make creation
operator-only; callers must then send `X-Workspace-Bootstrap-Secret`.
Even with open creation, set the bootstrap secret. Without it, the engine
fails closed (`503 workspace_create_idempotency_unavailable`) on anonymous
creates that send an `Idempotency-Key`.

### Secrets

The chart never renders secret values. Choose one of:

- `secrets.existingSecret`: a Secret you manage (default path).
- `externalSecrets.enabled=true`: renders an `ExternalSecret`
  (`external-secrets.io/v1`) against your `(Cluster)SecretStore`, for example
  one backed by 1Password. Only remote references go in values.

### Storage

`persistence.existingClaim` is the default and recommended path. Tools that
apply manifests without Helm's lifecycle (e.g. Alchemy) ignore
`helm.sh/resource-policy: keep`, so a chart-owned PVC can be deleted with the
release. `persistence.create=true` is for dev and test only. The volume holds
every tenant's data and files, so back it up.

### Ingress

Agents keep long-lived WebSockets open, so raise your controller's proxy
timeouts (see `values.yaml`).

## Image

`ghcr.io/agentworkforce/relaycast`, with the tag defaulting to `appVersion`.
Pin `image.digest` in production. `global.imageRegistry` rewrites the registry
for mirrors.

## Alchemy-safe contract

There are no `helm.sh/hook` annotations, no `lookup`/`randAlphaNum`/`genCA`,
and no `ttlSecondsAfterFinished`. `ci/kind-values.yaml` renders with zero edits.
