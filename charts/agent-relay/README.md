# agent-relay

Umbrella chart for the self-hosted messaging and Sessions proof:

- Relaycast and RelayAuth
- 96Bulls Sessions pipeline
- Relay History
- self-host control-plane API
- static dashboard

Relayflows is an optional add-on (`components.relayflows`, off by default;
see `docs/self-hosted-relayflows.md`). Relayfile is not a dependency.

## Customer-neutral GCP template

`values-gcp.yaml` is the customer-neutral starting point for a full GKE
deployment. It is derived from the proof configuration but uses only
`example-*` resource names, `placeholder.company` hosts, and customer-owned
Artifact Registry placeholders. It contains Secret names and keys, never
Secret values.

The template is intentionally renderable: all-zero image digests are sentinel
values, not deployable images. Replace every value marked `REQUIRED OVERRIDE`
before installing. The required value overrides are:

| Values path | Required replacement |
| --- | --- |
| `global.imageRegistry` | Artifact Registry hostname for the selected region, such as `us-central1-docker.pkg.dev`. |
| `global.tenant.orgId` | Stable customer organization ID. Do not change it after data has been written. |
| `gkeIngress.name`, `staticIpName`, `managedCertificateName`, `frontendConfigName` | Customer-selected names. `staticIpName` must name a reserved global external IPv4 address; the chart creates the other resources. |
| `gkeIngress.hosts.{root,api,cast,history}` | Four customer-controlled public DNS names whose A records point at the reserved address. |
| `relaycast.image.{repository,digest}` | Customer-accessible Relaycast image mirror and its real immutable digest. |
| `relayauth.image.{repository,digest}` | Customer-accessible RelayAuth image mirror and its real immutable digest. |
| `96bulls.worker.image.{repository,digest}` and `96bulls.alleyoop.image.{repository,digest}` | Repository path under `global.imageRegistry` and the same immutable Sessions services digest. |
| `relayhistory.image.{repository,digest}` | Customer-accessible Relay History image mirror and its real immutable digest. |
| `relay-cloud-api.image.{repository,digest}` | Customer-accessible control API image mirror and its real immutable digest. |
| `relay-dashboard.image.{repository,digest}` | Customer-accessible dashboard image mirror and its real immutable digest. |
| All `existingSecret` values set to `example-agent-relay-secrets` | Name of a pre-created Secret in the release namespace. Update every occurrence if separate Secrets are used. |
| `96bulls.{worker,alleyoop}.locker.bucket` | Existing customer-owned GCS bucket used for session objects. Both values must match. |
| `96bulls.{worker,alleyoop}.locker.region` | Region of that bucket. Both values must match. |
| `relaycast.baseUrl` | `https://` plus `gkeIngress.hosts.cast`. |
| `relayhistory.relayauth.historyOrigin` | `https://` plus `gkeIngress.hosts.history`. |
| `relay-cloud-api.publicUrl` | `https://` plus `gkeIngress.hosts.api`. |
| `relay-cloud-api.services.relaycastPublicUrl` | Same origin as `relaycast.baseUrl`. |
| `relay-cloud-api.services.relayhistoryPublicUrl` | Same origin as `relayhistory.relayauth.historyOrigin`. |
| `relay-dashboard.runtime.publicUrl` | `https://` plus `gkeIngress.hosts.root`. |

The referenced Secret must provide these keys:

- Relaycast: `relaycast-internal-secret` (at least 32 characters) and
  `relaycast-workspace-bootstrap-secret`
- RelayAuth: `relayauth-internal-secret`,
  `relayauth-signing-key.pem`, and `relayauth-bootstrap-api-key`
- Sessions: `HOOPDB_URL`, `HOOPDB_MIGRATION_URL`, and
  `SUMMARY_MASTER_KEYS`
- Relay History: `DATABASE_URL` and `DATABASE_MIGRATIONS_URL`
- control API: `database-url`, `database-migrations-url`,
  `relayauth-api-key`, `selfhost-bootstrap-token`, and
  `selfhost-encryption-key`
- RelayAuth-issued relaycast credentials (optional, model B):
  `relaycast-credential-keyring` and `relaycast-relayauth-token`

`relayauth-api-key` and `relayauth-bootstrap-api-key` must contain the same
value. `selfhost-bootstrap-token` must be at least 32 bytes.
`selfhost-encryption-key` must encode exactly 32 bytes as either 64 hexadecimal
characters or base64.

With `relaycast.credentials.authority=relayauth` (model B, see the commented
`credentials` block in `values-gcp.yaml`), RelayAuth owns the `ar_` credential
tag keyring and pushes `ar_ws_` workspace keys into Relaycast, which verifies
tags through RelayAuth's remote CredentialTagger. The shared Secret then needs
`relaycast-credential-keyring` (mounted by relayauth) and
`relaycast-relayauth-token` (mounted by relaycast); relayauth also mounts
`relaycast-internal-secret` to call Relaycast's internal admin API. It
requires `components.relayauth=true` and a >=12.3.x relaycast engine image.

When `components.relayflows=true` with `mode=cloudWorker`, the Secret named by
`relayflows.credentials.existingSecret` must contain the worker enrollment
token under `relayflows.credentials.existingSecretKey` (default
`AGENT_RELAY_WORKER_ENROLLMENT_TOKEN`). Alternatively
`relayflows.credentials.enrollmentToken` renders a chart-managed Secret — the
only case in which this chart renders Secret material. Standalone mode needs
no enrollment Secret; model and provider credentials reach the flow through
`relayflows.extraEnv`/`extraEnvFrom`.

The template assumes external Cloud SQL and GCS rather than in-cluster
Postgres and MinIO. Before installation, provision separate Sessions, Relay
History, and control API databases; install the Sessions database extensions
and migrations required by 96Bulls; and make each runtime URL use the
least-privilege role named in the values (`sessions_runtime` or
`control_api_runtime`). Migration URLs must use the corresponding
migration-owner roles. Relay History must have its own database and migration
ledger.

Grant the rendered Sessions worker and Alleyoop Kubernetes service accounts
GCS access through GKE Workload Identity, and grant GKE nodes or configured
image pull identities read access to every Artifact Registry repository. No
cloud credential belongs in this values file.

The umbrella Ingress is a global external GKE Application Load Balancer with
standalone NEGs. Each public backend NetworkPolicy admits its application port
from same-namespace pods and from the Google Front End proxy/health-check
ranges `35.191.0.0/16` and `130.211.0.0/22`. No other external source range is
allowed. The chart fails rendering when `gkeIngress.enabled=true` and any
public backend disables its policy or omits one of these three sources.

These Kubernetes policies do not replace the corresponding VPC firewall rule.
GKE normally creates that rule for an Ingress; Shared VPC deployments where
the service-project GKE identity cannot manage host-project firewall rules
must have an administrator allow the same two Google ranges to the NEG
backends on their serving ports. See the
[GKE Ingress firewall guidance](https://cloud.google.com/kubernetes-engine/docs/how-to/load-balance-ingress#shared_vpc).

Render the template before supplying any credentials:

```sh
helm lint . -f values-gcp.yaml
helm template agent-relay . -n agent-relay -f values-gcp.yaml >/dev/null
```

`values-gcp-proof.yaml` is the portable, all-components customer shape.
`values-gcp-proof-live.yaml` is a separate overlay for the existing proof
cluster; it reuses RelayAuth in the `relayauth` namespace, disables the
already-running Sessions pipeline, and inherits the portable profile's
restricted GKE NetworkPolicies.

One umbrella GKE Ingress reserves a global static address
(`gkeIngress.staticIpName`), uses one Google ManagedCertificate for all
four hosts, and enables HTTP-to-HTTPS redirect through a FrontendConfig.
For a base domain `relay.example.com`:

- `relay.example.com`: `/cloud/api` and `/login` to the control API,
  then `/` to the dashboard
- `api.relay.example.com`: the same control-plane API Service
- `cast.relay.example.com`: Relaycast
- `history.relay.example.com`: Relay History

Leaf ingresses are disabled and each ClusterIP backend uses a GKE standalone
NEG. Sensitive Relaycast paths still route to an endpoint-less deny Service.

All application credentials come from existing Secrets. The deployment values
contain no credentials and no imagePullSecret reference. Rendering fails until
all required immutable digests are present. The live proof pins:

- dashboard: `sha256:9bfc0c6b873411c7a0da60d746883bdef6aafd86a9b733c719500a603890b6fe`
- selfhost API: `sha256:0452a72da76d36c9c69ac6de75e51299b1df1a0fdfaec37831bff6deb55c7cf8`
- experimental RelayHistory: `sha256:8fbda9bd89dd33994b6b3331fb403c38a25f04e6742050bd717e99661f3544ba`

The RelayHistory image is an experimental proof build, not a released or
supported artifact.

The live overlay expects an existing Secret (the portable example names it
`example-agent-relay-secrets`) in the release namespace with these keys
(values are never stored in this repository):

- Relaycast: `relaycast-internal-secret`,
  `relaycast-workspace-bootstrap-secret`
- RelayHistory: `DATABASE_URL`, `DATABASE_MIGRATIONS_URL`
- selfhost-api: `database-url`, `database-migrations-url`,
  `relayauth-api-key`, `selfhost-bootstrap-token`,
  `selfhost-encryption-key`

`relayauth-api-key` must equal the existing RelayAuth bootstrap API key.
`selfhost-bootstrap-token` must be at least 32 bytes.
`selfhost-encryption-key` must encode exactly 32 bytes as 64 hex characters or
base64. Runtime database URLs should use least-privilege roles; migration URLs
must use the corresponding migration-owner roles.

The portable all-components shape additionally needs
`relayauth-internal-secret`, `relayauth-signing-key.pem`,
`relayauth-bootstrap-api-key`, `HOOPDB_URL`, `HOOPDB_MIGRATION_URL`, and
`SUMMARY_MASTER_KEYS` in that Secret. `relayauth-api-key` and
`relayauth-bootstrap-api-key` must contain the same API-key value.

```sh
helm dependency build charts/96bulls
helm dependency build charts/agent-relay
helm install agent-relay charts/agent-relay -n agent-relay \
  --create-namespace --no-hooks -f charts/agent-relay/values-gcp-proof.yaml \
  -f charts/agent-relay/values-gcp-proof-live.yaml \
  --set relay-cloud-api.image.digest=sha256:...
```

The proof uses single-writer/single-replica components and makes no HA claim.
Cloud SQL networking and database/user provisioning remain operator work.
RelayHistory must use its own database and migration ledger; do not point it at
the 96Bulls `hoopdb` database. The headless API supports both `/api/v1` and
Desktop/Dashboard `/cloud/api/v1` routes, including secure browser login,
workspace-scoped session search, and replay.
