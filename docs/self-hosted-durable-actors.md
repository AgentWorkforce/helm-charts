# Self-hosted Relaycast and Relayfile on TerseAI durable-actors

Status: implemented in the charts (render-tested), behind opt-in values.
Relaycast and Relayfile can each run their stateful core as one TerseAI
durable-actors `Workspace` actor per workspace, behind a stateless gateway,
instead of the single-node SQLite (Relaycast) or Go-server (Relayfile)
deployments. The umbrella can run the durable-actors control plane itself.

| Piece | Where |
| --- | --- |
| Control plane | `charts/durable-actors`, the upstream release chart vendored verbatim at v0.14.6 (`charts/durable-actors/UPSTREAM.md`), umbrella `components.durableActors`, values key `durable-actors` |
| Relaycast actor mode | `charts/relaycast` `runtime.backend: durable-actors` (env contract v1, below) |
| Relayfile actor mode | `charts/relayfile` `runtime.backend: durable-actors`, umbrella `components.relayfile` |
| Requirements and options | `self-hosted/requirements.yaml` profiles `durable-actors`, `relaycast-durable-actors`, `relayfile-durable-actors`, `agent-relay-durable-actors` |
| Render contract | `ci/agent-relay/render.sh`, `scripts/ci/charts.sh static` |

One backend name is used everywhere: `durable-actors` (upstream renamed the
project and chart from Terse to durable-actors; `TERSE_*` env names are gone).

## Architecture

```
client ──HTTPS──▶ cast.<domain> / files.<domain> (umbrella GKE Ingress)
                    │  cast: /internal and /v1/workspaces exact → edge-deny (unchanged)
                    ▼
        relaycast gateway / relayfile gateway   (stateless Deployments, N replicas)
                    │  route by verified credential → Workspace[<workspace id>]
                    │  file bytes → GCS or S3 (never inside actors)
                    ▼
        durable-actors control plane  <release>-durable-actors:7100
                    │  placement, host start, invocation proxy, socket grants
                    │  publicUrl https://actors.<domain> (SDK follow-up calls, actor WebSockets)
                    ▼
        Workspace actor pods (gVisor, sandbox namespace <ns>-<release>)
                    engine on actor SQLite; state in the Standard GCS bucket
                    alarm: maintenance, outbound delivery
```

- Actor hosts are created by the control plane with `runtimeClassName: gvisor`,
  `nodeSelector: sandbox.gke.io/runtime=gvisor` and a zone affinity from
  `placement.zone`. GKE's `gvisor` RuntimeClass adds the sandbox node taint
  toleration. Nothing in this repo patches that.
- The sandbox NetworkPolicy (upstream) admits only control-plane pods on
  7101/7102 and allows egress to the control plane, DNS and **public** addresses
  only (RFC1918, link-local and CGNAT are denied). Anything an actor fetches,
  such as Relaycast's own `RELAYCAST_PUBLIC_URL`, must be a public HTTPS origin.
- The umbrella adds a NetworkPolicy for the control plane (port 7100): pods in
  the release namespace, the sandbox namespace and, with
  `gkeIngress.hosts.actors`, the GKE load balancer ranges.
- `publicUrl` is required and HTTPS. With `gkeIngress.hosts.actors` the
  umbrella routes it on the suite load balancer (same static IP and managed
  certificate) through an umbrella-owned edge Service that selects the control
  plane pods, carries the NEG annotation and a BackendConfig with a long
  timeout (`gkeIngress.actorsBackendTimeoutSec`, default 3600 s) for actor
  WebSockets. Set `durable-actors.ingress.enabled=false` then (one edge only).

## Upstream durable-actors (0.14.6) facts the charts rely on

- Chart `charts/durable-actors` (also `oci://ghcr.io/terseai/charts/durable-actors`).
  Required values: `publicUrl` (https), `placement.zone`, `storage.bucket`,
  `serviceAccount.googleServiceAccount`. Image digests are pinned by the release.
- Storage: **one Standard GCS bucket** (ownership, compiled code under
  `durable-actors/v3/artifacts/<uuid>/`, state snapshots). Rapid
  (`storage.mode: rapid`, one or two RAPID buckets in distinct zones) is optional.
  No lifecycle deletion on any of them. No S3, MinIO or PVC provider exists.
- `credentialsSecret` keys: `postgres-url`, `jwt-signing-key` (base64 Ed25519
  PKCS#8 DER, stable), `api-key`, plus `redis-url` (and `redis-ca`) when
  `replicaCount > 1`; more than one controller requires Redis.
- Providers: GKE Sandbox or Modal only. `durable-actors dev` (single process,
  local storage, binds 127.0.0.1, actors inherit its process env, secretRefs
  rejected) is the only way to run actors without GKE + GCS.
- Auth: a single administrative `api-key` (`DURABLE_ACTORS_SECRET`). Auth is
  disabled when it is unset, so every chart here fails closed without one.
  `POST /v1/projects/{project}/sessions` (admin key) issues sessions of at most
  60 s that can invoke actors of one project but cannot register deployments or
  get socket grants. A scoped invoke-only key is proposed upstream, not shipped.
- Deployments are registered with `PUT /v1/projects/{project}/deployment` (admin
  key): a compiled bundle in the artifact bucket, its contract and optional
  `secretRefs` (Secrets in the sandbox namespace labelled
  `terse.ai/customer-secret=true` whose keys become actor env).

Vendored-chart patch: the upstream schema forbids the `global` key Helm
injects into every subchart, so the vendored schema allows a root `global`
object (recorded in `UPSTREAM.md`; report upstream).

## Relaycast env contract v1 (`runtime.backend: durable-actors`)

Frozen by the relaycast branch `selfhost/terse-actors-relaycast`. All wiring is
in `charts/relaycast/templates/_actors.tpl`.

| Process | Variables (chart source) |
| --- | --- |
| gateway (`relaycast-actors-gateway`, PORT 8787, `/healthz` liveness, `/readyz` readiness) | `DURABLE_ACTORS_CONTROL_PLANE_URL` (default `http://<release>-durable-actors.<ns>.svc.cluster.local:7100`), `DURABLE_ACTORS_PROJECT_ID`, `DURABLE_ACTORS_SECRET` (from `runtime.durableActors.invocationSecret`, its own Secret), `DURABLE_ACTORS_HOME_REGION` (optional), `RELAYCAST_FILE_SIGNING_SECRET` (existingSecret key `fileSigningSecretKey`), `RELAYCAST_CREDENTIAL_KEYRING_FILE`, `RELAYCAST_INTERNAL_SECRET_FILE`, `RELAYCAST_PUBLIC_WORKSPACE_CREATE` (`publicWorkspaceCreate`, default false), `RELAYCAST_FILE_STORE` local\|gcs\|s3 with `RELAYCAST_FILE_DIR` / `RELAYCAST_GCS_BUCKET`,`_PREFIX` / `RELAYCAST_S3_BUCKET`,`_REGION`,`_ENDPOINT`,`_PREFIX`,`_FORCE_PATH_STYLE` (+ `AWS_*` from `fileStore.s3.existingSecret`), `RELAYCAST_MAX_UPLOAD_BYTES`, `RELAYCAST_SHUTDOWN_GRACE_MS`, `RELAYCAST_LOG_FORMAT`, `RELAYCAST_ENV` |
| Workspace actor (customer Secret in the sandbox namespace, `runtime.durableActors.actorEnvSecrets`) | `RELAYCAST_PUBLIC_URL` (= `baseUrl`, public HTTPS), `RELAYCAST_FILE_SIGNING_SECRET`, `RELAYCAST_INTERNAL_SECRET`, optional `RELAYCAST_MAX_UPLOAD_BYTES`, `RELAYCAST_MESSAGE_TTL_DAYS`, `RELAYCAST_MAILBOX_TTL_MS`, `RELAYCAST_MAILBOX_DEPTH_CAP`, `RELAYCAST_RATE_LIMIT_PER_MINUTE`, `RELAYCAST_ENV` |
| deployer Job (`relaycast-actors-deployer`) | `DURABLE_ACTORS_CONTROL_PLANE_URL`, `DURABLE_ACTORS_PROJECT_ID`, `DURABLE_ACTORS_ORGANIZATION_ID`, `DURABLE_ACTORS_SECRET` (admin, `adminKeySecret`), `DURABLE_ACTORS_ARTIFACT_BUCKET`, `DURABLE_ACTORS_SECRET_REFS` |

Chart behaviour and validation:

- The gateway Deployment keeps the SQLite Deployment's name and selector, so the
  Service, edge-deny Service, Ingress, umbrella `gkeIngress` and NetworkPolicy are
  unchanged. The SQLite render is byte-identical apart from the chart label.
- The gateway never mounts the admin key: `invocationSecret` must differ from
  `adminKeySecret` and from `existingSecret`. `invocationSecret.scope: admin`
  records that it is still a copy of the admin key (NOT release-grade); when
  upstream ships the invoke-only key, change the Secret's value and set
  `scope: invoke-only`.
- Requires `credentials.format=ar` and a keyring, an HTTPS public `baseUrl` (no
  `allowInsecureBaseUrl`), and no SQLite-only settings (`backup`, `retention`,
  `mailbox`, `bootstrapProofRequired`; set those as actor env instead).
- `gateway.replicaCount > 1` requires `fileStore` gcs or s3. `local` renders the
  data PVC and one replica.
- The deployer is a plain Job whose name carries a hash of its pod template:
  installs run `helm template --no-hooks`, so Helm hooks never run. New inputs
  give a new Job; an unchanged re-apply is a no-op.
- `devRuntime` (kind/CI only, `acknowledgeNonProduction: true`): a
  `durable-actors dev` sidecar in the gateway pod (image
  `relaycast-actors-dev`, the durable-actors TypeScript runtime plus the
  relaycast actor project and the full `durable-actors` npm package). The actor
  env is set on the sidecar.

Fresh-install backend: SQLite workspaces are not migrated and legacy
credentials are refused; keep the SQLite release for existing workspaces.

## Relayfile env contract v1 (`runtime.backend: durable-actors`)

All wiring is in `charts/relayfile/templates/actors/_helpers.tpl`. One image
`relayfile-actors` with three commands.

| Process | Variables |
| --- | --- |
| `gateway` (Deployment `<fullname>-server`, port `server.port`) | `PORT`, `DURABLE_ACTORS_CONTROL_PLANE_URL`, `DURABLE_ACTORS_PROJECT_ID`, `RELAYFILE_ACTORS_BROKER_URL`, `RELAYFILE_ACTORS_BROKER_TOKEN`, `RELAYFILE_JWT_SECRET` and/or `RELAYAUTH_JWKS_URL`, optional `RELAYFILE_INTERNAL_HMAC_SECRET`, `RELAYFILE_BLOB_STORE` gcs\|s3\|inline, `RELAYFILE_BLOB_BUCKET`, `RELAYFILE_BLOB_PREFIX`, `RELAYFILE_BLOB_INLINE_MAX_BYTES`, `RELAYFILE_S3_ENDPOINT`,`_REGION`,`_FORCE_PATH_STYLE` + `AWS_*`; devRuntime only: `DURABLE_ACTORS_SECRET`, `RELAYFILE_ACTORS_ALLOW_ADMIN_KEY=true` |
| `session-broker` (internal Deployment + Service, port 8090) | `PORT`, `DURABLE_ACTORS_CONTROL_PLANE_URL`, `DURABLE_ACTORS_PROJECT_ID`, `DURABLE_ACTORS_SECRET` (admin), `RELAYFILE_ACTORS_BROKER_TOKEN` |
| `deploy` (Job) | `DURABLE_ACTORS_CONTROL_PLANE_URL`, `DURABLE_ACTORS_PROJECT_ID`, `DURABLE_ACTORS_SECRET` (admin), `DURABLE_ACTORS_ORGANIZATION_ID`, `DURABLE_ACTORS_ARTIFACT_BUCKET` |
| Workspace actor | none (no secrets in actors; bytes stay in the gateway's object store) |

- Least privilege without an upstream scoped key: the session broker is the only
  long-running workload that reads the admin key. It issues 60 s sessions
  (invoke only) and Workspace socket grants to the gateway, authenticated by the
  broker token, and its NetworkPolicy admits only gateway pods.
- The gateway Deployment keeps the Go server's name and selector (Service,
  Ingress, HPA, PDB, NetworkPolicy shared). The default `go` render is unchanged.
- `adminKeySecret` must differ from `runtime.durableActors.existingSecret`;
  `blobStore.driver: inline` is refused unless `devRuntime`; images by digest
  (a tag is accepted for local proofs only).

## Umbrella wiring (`charts/agent-relay`)

- `components.durableActors` needs an actor-mode consumer; an actor-mode
  consumer needs `components.durableActors` (or its own `controlPlaneUrl`).
- Consumers' `adminKeySecret.name` must equal `durable-actors.credentialsSecret`
  and `deployer.artifactBucket` must equal `durable-actors.storage.bucket`.
- `gkeIngress.hosts.actors` requires `durable-actors.publicUrl` =
  `https://<hosts.actors>`; `gkeIngress.hosts.files` routes Relayfile and requires
  `relayfile.service.annotations["cloud.google.com/neg"]`.
- GKE overlay: `charts/agent-relay/values-gcp-proof-durable-actors.yaml`
  (apply after the proof profile; supply the three actor image digests).
- kind shape: `ci/agent-relay/kind-durable-actors-values.yaml` (devRuntime
  sidecars and MinIO; no control plane).

## GCP provisioning (per installation)

Placeholders: `PROJECT`, `REGION`, `ZONE` (a zone of the GKE Sandbox node
pool), release `REL` in namespace `NS` (sandbox namespace `NS-REL`).

1. Cluster: GKE Standard, Workload Identity, NetworkPolicy enforcement, a GKE
   Sandbox (gVisor) node pool with nodes in `ZONE`.
2. Buckets (uniform access, public access prevention, no lifecycle deletion):
   - `PROJECT-actors`: STANDARD, `REGION` (durable-actors state and code).
   - `PROJECT-relaycast-files`: STANDARD, `REGION` (Relaycast `/_relayfiles`).
   - `PROJECT-relayfile`: STANDARD, `REGION` (Relayfile blobs).
   - Optional Rapid: two RAPID buckets with hierarchical namespace in two zones.
3. Google service accounts and Workload Identity bindings
   (`roles/iam.workloadIdentityUser` on member
   `serviceAccount:PROJECT.svc.id.goog[NS/<ksa>]`):
   - `durable-actors@` → KSA `REL-durable-actors`; `roles/storage.objectUser`
     on `PROJECT-actors` (and `roles/storage.legacyBucketReader` for Rapid).
   - `actors-deployer@` → KSAs `<relaycast fullname>-actors-deploy` and
     `<relayfile fullname>-actors-deploy`; `roles/storage.objectUser` on
     `PROJECT-actors`.
   - `relaycast-files@` → KSA of the relaycast chart; `roles/storage.objectUser`
     on `PROJECT-relaycast-files`.
   - `relayfile@` → KSA of the relayfile chart; `roles/storage.objectUser` on
     `PROJECT-relayfile`.
4. PostgreSQL: a database and a role allowed to run migrations (for example a
   `durable_actors` database on an existing Cloud SQL instance, reached through
   a Cloud SQL proxy or private IP, TLS for remote connections).
5. Redis (Memorystore, TLS) only for `durable-actors.replicaCount > 1`.
6. Secrets (namespace `NS` unless noted; generate with `openssl`, never commit):
   - `actors-credentials`: `postgres-url`, `jwt-signing-key`
     (`openssl genpkey -algorithm ED25519 -outform DER | openssl base64 -A`),
     `api-key` (`openssl rand -hex 32`), optional `redis-url`/`redis-ca`.
   - Relaycast `existingSecret`: `internal-secret`, `workspace-bootstrap-secret`,
     the credential keyring (`{"current":"a","keys":{"a":"<random>"}}`), the file
     signing secret.
   - Relaycast invocation Secret (for example `relaycast-durable-actors-invoke`):
     `durable-actors-invoke-key` = the `api-key` value until an invoke-only key exists.
   - Sandbox namespace `NS-REL`: `relaycast-actor-env`, labelled
     `terse.ai/customer-secret=true`, with `RELAYCAST_PUBLIC_URL`,
     `RELAYCAST_FILE_SIGNING_SECRET` (same value), `RELAYCAST_INTERNAL_SECRET`
     (same value). The chart renders the sandbox Namespace, so create this Secret
     after the first install, or pre-create the Namespace with Helm ownership
     metadata (`app.kubernetes.io/managed-by: Helm`, annotations
     `meta.helm.sh/release-name: REL`, `meta.helm.sh/release-namespace: NS`) so
     the release adopts it. A deployer Job that ran before the Secret existed
     must be deleted to run again.
   - `relayfile-actors`: `RELAYFILE_JWT_SECRET` (unless `auth.jwksUrl`),
     `RELAYFILE_ACTORS_BROKER_TOKEN`, optional `RELAYFILE_INTERNAL_HMAC_SECRET`.
7. DNS: `actors.<domain>` and `files.<domain>` A records on the suite static IP
   (the managed certificate gains both domains).
8. Images (by digest): `relaycast-actors-gateway`, `relaycast-actors-deployer`
   (relaycast repo `docker/actors-gateway.Dockerfile`,
   `docker/actors-deployer.Dockerfile`), `relayfile-actors` (relayfile repo).
   The durable-actors images are pinned by the vendored chart.

## kind / local proof

kind cannot run the upstream control plane (no GKE Sandbox, no GCS). The kind
shape runs each gateway with a `durable-actors dev` sidecar (`devRuntime`),
MinIO for file bytes, and locally built images loaded with `kind load
docker-image` (tag `kind`, `pullPolicy: Never`):

```sh
helm install agent-relay charts/agent-relay -n agent-relay \
  -f ci/agent-relay/kind-durable-actors-values.yaml
```

The dev runtime needs the full `durable-actors` npm package (the published
runtime image ships only the actor host, not the compiler) and
`--sdk-host <project>/node_modules/durable-actors/dist/host.js`.

## Known gaps

- Upstream has no invoke-only credential: Relaycast's gateway still holds a copy
  of the admin key (`invocationSecret.scope: admin`); Relayfile isolates it in
  the session broker. Socket grants (`find-websocket`) need the admin key.
- No SQLite → actors migration tooling; actor mode is a fresh-install backend.
- Non-GKE self-host (generic Kubernetes, S3/MinIO actor storage) is an upstream
  gap.
- Changing an installation's `storage.mode` or bucket identities needs a data
  migration; a values change alone does not move actor state.
