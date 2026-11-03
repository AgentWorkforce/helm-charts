# relay-cloud-api

Maintained packaging for `packages/selfhost-api` from the Cloud repository.
It provides the minimal self-host control API and does not package the full
Cloud/Next application.

`image.digest` and `existingSecret` are mandatory. The Secret keys are listed
in `values.yaml`; all values are mounted as files. The migration Job projects
only `database-migrations-url`; the API pod cannot read that key. The chart
never creates a Secret or renders credentials. Set `database.runtimeRole` to
the non-secret PostgreSQL role used by `database-url`; after migrations, the
owner grants that role runtime access only to `selfhost_*` application tables.

The image must contain the compiled `@cloud/selfhost-api` package. The server
runs `node node_modules/@cloud/selfhost-api/dist/server.js`; migrations run
`node node_modules/@cloud/selfhost-api/dist/migrate-cli.js`.
`services.relaycastUrl` and `services.relayhistoryUrl` are internal origins;
their `*PublicUrl` counterparts must be public HTTPS origins and are returned
to clients or used as the externally stable RelayHistory assertion audience.

Requires Helm 3.10 or newer (templates use `{{ continue }}`).

## relaycontrol runtime settings

The authoritative contract is the requirements registry
(`self-hosted/requirements.yaml`, rendered to
[docs/self-hosted-requirements.md](../../docs/self-hosted-requirements.md));
this table summarizes it. The chart renders the relaycontrol env contract and refuses at render time
whatever the API would refuse at startup:

| Value | Env | Notes |
| --- | --- | --- |
| `encryption.keyId` (required) | `SELFHOST_ENCRYPTION_KEY_ID` | Non-secret id of `secretKeys.encryptionKey`, 1-64 URL-safe characters. |
| `encryption.previousKeyId` + `secretKeys.previousEncryptionKey` | `SELFHOST_ENCRYPTION_PREVIOUS_KEY_ID`, `SELFHOST_ENCRYPTION_PREVIOUS_KEY_FILE` | Key rotation; both or neither, and the id must differ from `keyId`. |
| `secretKeys.internalToken` | `SELFHOST_INTERNAL_TOKEN_FILE` | Optional service bearer for `/internal/v1` (flows env delivery, telemetry issue reports). Never expose `/internal` publicly: with `ingress.enabled` this chart routes `/internal` to a selector-less deny Service, and the agent-relay GKE ingress denies it at the edge. |
| `dashboardUrl` | `SELFHOST_DASHBOARD_URL` | Where OAuth callback pages and flow `runUrl`s point. Defaults to `publicUrl` + `/` in the API. |
| `flows.storage`, `flows.gcsBucket`, `flows.gcsPrefix` | `SELFHOST_FLOWS_STORAGE`, `SELFHOST_FLOWS_GCS_BUCKET`, `SELFHOST_FLOWS_GCS_PREFIX` | `postgres` (default) or `gcs` (Workload Identity; bucket required). |
| `flows.workerRelaycastUrl` | `SELFHOST_FLOWS_WORKER_RELAYCAST_URL` | Optional Relaycast origin handed to workers. |
| `flows.queuePingMs` | `SELFHOST_FLOWS_QUEUE_PING_MS` | SSE keepalive, 1000-120000 ms; keep it below proxy timeouts. |
| `telemetry.level` | `SELFHOST_TELEMETRY_LEVEL` | `off` (chart default, the same as the API default), `errors` or `full`. |
| `telemetry.transport` | `SELFHOST_TELEMETRY_TRANSPORT` | Optional; `https` (default) or `file` (reports stay in the outbox for a signed export). |
| `telemetry.installId`, `secretKeys.telemetryInstallKey` | `SELFHOST_TELEMETRY_INSTALL_ID`, `SELFHOST_TELEMETRY_INSTALL_KEY_FILE` | Both required unless the level is `off`. |
| `telemetry.endpoint` | `SELFHOST_TELEMETRY_ENDPOINT` | Required only when the level is not `off` and the transport is `https`; optional with `file`. Must be an https URL. |
| `telemetry.egressTo` | (NetworkPolicy) | Destinations of the telemetry egress rule; empty by default. It must not be empty when the level is not `off`, the transport is `https`, `networkPolicy.enabled=true` and `networkPolicy.allowAllEgress=false`, and is unused otherwise. |
| `telemetry.probes` | `SELFHOST_TELEMETRY_PROBES` | Up to 20 extra health probes; `name` is a string of lowercase letters, digits and dashes (quote numeric names). |
| `telemetry.deployment` | `SELFHOST_TELEMETRY_DEPLOYMENT` | Extra flat deployment-shape keys (at most 32): string, number or boolean values only, version-like strings without `//`; the chart-rendered keys (`chart`, `chartVersion`, `appVersion`, `replicas`, `flowsStorage`, `networkPolicy`, `ingress`) cannot be overridden. |

Every non-empty `secretKeys.*` value must name a distinct Secret key; the
chart refuses collisions, so the migration credential
(`secretKeys.databaseMigrationsUrl`) is never mounted into the API pod.

The chart adds a TCP 443 egress rule to `telemetry.egressTo` only when all of
these hold: `networkPolicy.enabled=true`, `networkPolicy.allowAllEgress=false`,
the level is not `off`, and the transport is `https`. With NetworkPolicy
disabled, or with `allowAllEgress=true`, egress is not restricted and no rule
is rendered. The migration Job's NetworkPolicy never gets this rule.

The current runtime is deliberately one replica with `Recreate`: login/device
rate limiting remains process-local. This is a GCP proof shape, not HA.

`networkPolicy.enabled` defaults to true with `allowAllEgress: false`, which
allows egress only to same-namespace pods and DNS. The external PostgreSQL
database (and any service URL outside the namespace) is then unreachable, so
the chart refuses to render until you either list it in
`networkPolicy.additionalEgress` (each rule with a non-empty `to`) or set
`allowAllEgress: true`, as the umbrella GCP profiles do.

The migration is a normal deterministic Job because this repository installs
with `helm template --no-hooks`. An operator or reconciler must wait for it to
complete before considering a rollout successful; the API stays unready while
its database schema is unavailable.

```sh
helm lint --strict charts/relay-cloud-api \
  -f charts/relay-cloud-api/ci/default-values.yaml
```
