# Self-hosted Relaycast on TerseAI/durable-actors

Status: design. Replaces the single-node SQLite Relaycast backend with the
open-source, self-hostable Terse durable-actors runtime running in-cluster.

## Goal

Run the relaycast engine on [TerseAI/durable-actors](https://github.com/TerseAI/durable-actors)
(MIT) instead of the single-process Node + SQLite deployment. One `Workspace`
actor per relaycast workspace, each with its own SQLite state inside the
actor — the open-source, self-hostable replacement for the Cloudflare Durable
Objects shape used by the hosted "armadillo" proof.

The actor adapter already exists and is merged upstream:

- `@relaycast/engine/adapters/actor` (`packages/engine/src/adapters/actor/`,
  relaycast PR #599, requires durable-actors >= 0.14.5). `createActorRuntime`
  runs the full engine on the actor's SQLite: one actor call = one
  transaction; engine write groups nest inside it; maintenance (webhooks,
  deliveries, A2A egress, sweeps, retention) runs on the actor alarm, never
  inside a request.
- `@relaycast/engine/gateway` exports the gateway helpers
  (`createCredentialTagSigner`, `parseArCredential`, `verifyFileToken`,
  `generateWorkspaceId`, `ACTOR_FILE_ROUTE`, ...).
- `examples/terse/` in the relaycast repo is the working proof:
  `actor/src/workspace.ts` (the `Workspace` actor) and `gateway/server.ts`
  (Bun gateway routing by `ar_` credential).

## Architecture

```
client ──HTTPS──▶ cast.<domain> (existing gke-ingress / leaf ingress)
                    │  /internal, /v1/workspaces exact → edge-deny (unchanged)
                    ▼
            relaycast gateway (new Deployment, Bun, replaces engine pod)
                    │  Bearer ar_<kind>_<wsid>_<tag>_<secret><crc>
                    │  ├─ POST /v1/workspaces → sign tag for new snowflake
                    │  └─ keyring verifies tag; forged/typo creds never create actors
                    ▼
            terse-sdk createActorStub("Workspace", wsid)
                    │  POST {cp}/v1/projects/{p}/actors/Workspace/{id}/invoke
                    ▼
            terse control plane (Deployment x2, in release namespace)
                    │  resolves placement, starts host if cold,
                    │  proxies the invocation to the actor host
                    ▼
            Workspace actor pod (gVisor sandbox in terse-sandboxes ns,
            runtime image = durable-actors image, code from artifact bucket)
                    │  engine on actor SQLite; state in GCS (2x Rapid + Standard)
                    └─ alarm: maintenance, outbound HTTP, blob cleanup
```

Request flow details:

- The relaycast gateway is stateless for routing: an `ar_` credential names
  its workspace (64-bit snowflake), the gateway's
  `RELAYCAST_CREDENTIAL_KEYRING` (`{"current":"a","keys":{"a":"<secret>"}}`)
  verifies the embedded tag, then the call goes to `Workspace[wsid].handle`.
  Rotation adds a key version and makes it current; removing a version locks
  out every credential tagged under it.
- `terse-sdk` first calls the control plane `/invoke`, which performs the
  invocation itself and returns `{route, token}`. `route` is
  `DURABLE_ACTORS_PUBLIC_URL` whenever the gateway origin is configured (it
  always is in the upstream chart — `publicUrl` is required and must be
  `https://`; `src/control_plane/process.rs` requires HTTPS). Follow-up calls
  go to `publicUrl`, which routes through the L7 LB back to the same
  control-plane service, which proxies to the host. So **every actor call is
  proxied by the control plane**; the public URL hop costs one extra LB
  traversal for in-cluster callers. Options, in order of preference for the
  GCP proof:
  1. `publicUrl` = a real DNS host on the cluster's external LB
     (e.g. `actors.<domain>`). In-cluster calls hairpin through the LB — fine,
     and it also makes future external actor WebSocket URLs work.
  2. `publicUrl` = an internal HTTPS name (schema only requires `https://`).
     Needs TLS for that name (cert-manager private issuer + pod trust) — more
     PKI work for no functional gain. Only if public ingress is impossible.
- Clients (and the relaycast gateway) never talk to actor pods directly. The
  vendored sandbox NetworkPolicy already enforces this: only control-plane
  pods reach sandbox 7101/7102.
- File blobs never enter actors. `SignedUrlFileStorage` in the actor mints
  signed URLs at `{RELAYCAST_PUBLIC_URL}/_relayfiles?token=…`; the gateway's
  `serveFile` does PUT/GET/HEAD/DELETE against its file store. Actor pods do
  HEAD (upload completion) and DELETE (cleanup) against that public URL, so
  **`baseUrl`/`RELAYCAST_PUBLIC_URL` must be reachable from sandbox egress** —
  the vendored sandbox NetworkPolicy allows public egress but *blocks*
  RFC1918/private ranges. The `allowInsecureBaseUrl` cluster-internal path
  therefore cannot work for this backend without loosening the sandbox egress
  policy (a candidate vendored patch). For the GCP proof, `cast.<domain>` is
  public and works as shipped.
- Outbound webhooks/http_push/A2A egress run from the actor alarm only,
  HTTPS-only with SSRF checks (same as hosted).
- Known functional gap vs the sqlite backend: the example gateway serves no
  `/v1/ws` or `/v1/node/ws`, and `wait` returns immediately inside an actor
  (no deliveryWaiters — a parked wait would deadlock the mailbox). Realtime
  node transport over actor WebSockets is relaycast-repo work (below).

### What runs where

| Component | Runs as | State |
| --- | --- | --- |
| terse control plane | Deployment x2 (upstream chart enforces >= 2) in release ns | Postgres (registry, traces, spare pool); state in GCS buckets |
| actor host pods | 1 gVisor pod per active actor, `sandboxNamespace` (default `terse-sandboxes`), runtime image = `image.repository@digest` from the terse chart | actor SQLite is *derived* per activation from GCS logs/snapshots; nothing durable on the pod |
| spare pool | `pool.idle` (default 64) prewarmed sandboxes per region; `capacityBuffer` GKE CapacityBuffer optional | none |
| relaycast gateway | Deployment (new backend mode in `charts/relaycast`), ClusterIP `relaycast:8787` | file blobs on `RELAYCAST_FILE_DIR` (PVC) until an object-store backend lands upstream |
| terse Postgres | Cloud SQL proxy sidecar or direct `postgres-url` | can share the 96bulls Cloud SQL instance with its own database |

### Storage choices

Actor state storage is **GCS-only** in the upstream Kubernetes provider
(`src/sandbox/gke.rs` + `charts/terse`):

- `storage.authorityBucket` — Standard GCS, CAS ownership/leases.
- `storage.artifactBucket` — Standard GCS, immutable compiled actor code.
- `storage.archiveBucket` — Standard GCS, permanent manifests/checkpoints/
  archived log segments.
- `storage.rapid.buckets` — **exactly two** GCS Rapid (hierarchical namespace)
  buckets in distinct zones; every acknowledged write flushes to both.
- Postgres — control-plane registry/trace/spare bookkeeping; chart supports
  Cloud SQL (`cloudSql.instanceConnectionName`, proxy sidecar) or a direct
  `postgres-url` in `credentialsSecret` (e.g. an in-cluster CNPG instance or a
  second database on the 96bulls Cloud SQL instance).

There is **no S3/MinIO/PVC actor-storage backend upstream** for the k8s path.
`DURABLE_ACTORS_STORAGE=local` exists only for the single-process
`durable-actors dev` mode. Non-GKE self-host (generic PVC/MinIO, non-gVisor
sandboxes) is an upstream gap — out of scope for the GCP proof; if needed we
would have to contribute a provider upstream.

Relaycast file blobs are separate: today the example gateway writes them to
its own disk (`RELAYCAST_FILE_DIR`). Options: (a) RWO PVC + gateway
`replicaCount: 1` — same single-writer constraint as today's sqlite chart,
fine for the proof; (b) shared object store (GCS/MinIO) behind `serveFile` —
relaycast-repo change, required before running >1 gateway replica or losing
the file store on node failure.

## Chart strategy — vendor `charts/terse`

Decision: **vendor the upstream `charts/terse` chart, unpacked, at
`charts/terse/` in this repo**, pinned to an upstream release tag (currently
`v0.7.9`, chart `0.7.9`), and add it to the umbrella as a `file://../terse`
dependency conditioned on `components.terseActors`.

Why not the alternatives:

- **Helm dependency on a published repo/OCI:** not possible. Upstream's
  release workflow (`.github/workflows/release.yml`) only runs
  `helm package charts/terse` and `gh release upload` — the chart ships as a
  release asset `terse-0.7.9.tgz` on the git tag. There is no Helm repo
  `index.yaml` and no `oci://` push, and a Chart.yaml `repository:` cannot
  point at a bare release-asset URL.
- **Thin wrapper chart (`charts/terse-actors`):** rejected. It would add no
  capability the upstream values schema lacks (the chart is already fully
  values-driven), would still need to vendor or duplicate the upstream
  templates, and would obscure provenance. Prefer carrying zero or minimal
  patches on the vendored copy and pushing fixes upstream.
- **Download the tgz at build time:** makes renders network-dependent and
  harder to review than a committed, reviewed copy; the umbrella already
  vendors all leaf charts by `file://` sibling reference with committed tgzs
  in `charts/agent-relay/charts/`.

Vendoring procedure (when implemented): copy `charts/terse/` from the
upstream tag verbatim, record tag + sha256 of the upstream tgz in
`docs/` or a `charts/terse/UPSTREAM` note, and update deliberately. Known
upstream quirks to note (report upstream rather than patch, unless blocking):

- `templates/control-plane.yaml` reads `.Values.storage.durability` but
  `values.schema.json` declares `storage` with `additionalProperties: false`
  and no `durability` key, so it can never be set (evaluates nil, i.e. not
  `"zonal"` → `minDomains: 2` always applies).
- `networkPolicy.enabled` is `const: true` in the schema and
  `replicaCount >= 2` plus `>= 2` zones per region are enforced by
  `terse.validate` — single-zone/single-replica dev installs are refused by
  design.
- Sandbox egress policy denies RFC1918 — matters only if we ever point
  `RELAYCAST_PUBLIC_URL` at a private address (see above).

## Values schema sketch

### Umbrella (`charts/agent-relay`)

```yaml
components:
  terseActors: false          # new; requires components.relaycast
  # ...existing keys

terse:                        # passed through to the vendored chart
  image:
    repository: us-central1-docker.pkg.dev/fluid-analogy-473415-c2/public/durable-actors
    digest: ""                # REQUIRED, sha256 (chart requires it)
  replicaCount: 2
  publicUrl: https://actors.<domain>   # REQUIRED, https origin
  region: north-america-west           # a supported canonical region
  zones:
    north-america-west: [us-west4-a, us-west4-b, us-west4-c]
  storage:
    authorityBucket: <name>
    artifactBucket: <name>
    archiveBucket: <name>
    rapid:
      buckets:
        - { bucket: <name>, zone: us-west4-a }
        - { bucket: <name>, zone: us-west4-b }
  cloudSql:
    instanceConnectionName: ""  # or direct postgres-url in credentialsSecret
  credentialsSecret: terse-credentials   # keys: postgres-url, jwt-signing-key, api-key
  serviceAccount:
    googleServiceAccount: terse@<project>.iam.gserviceaccount.com
  pool: { idle: 8, fleetMaximum: 64, maxStarting: 8, idleTtlSeconds: 600,
          cpuMillis: 1000, memoryMiB: 256 }   # sized down from upstream defaults for proof
  capacityBuffer: { enabled: false, replicas: 32 }  # needs GKE preview API; off by default
  gateway:
    enabled: true               # front the control plane on publicUrl
    className: gke-l7-global-external-managed
    tlsSecret: ""               # or preSharedCert; exactly one required when enabled
  networkPolicy: { enabled: true, dnsCidrs: [] }
```

Plus a new `gkeIngress.hosts.actors` (or reuse of the terse chart's own
Gateway) so `publicUrl` terminates TLS. The vendored chart renders its own
`Gateway`/`HTTPRoute`/`HealthCheckPolicy`/`GCPBackendPolicy` when
`gateway.enabled`; using it avoids touching `gke-ingress.yaml`, at the cost
of a second LB. Folding the actors host into the umbrella's existing GCE
Ingress is also possible (neg annotation on `<release>-terse:7100`) —
choose one; don't render both.

### Leaf (`charts/relaycast`), `runtime.backend: terse-actors`

`runtime.backend` gains a second allowed value. In this mode the Deployment
runs the **gateway image**, not the engine; the Service stays
`<fullname>:8787` so the umbrella, ingress, edge-deny rules and
`relay-cloud-api` (`services.relaycastUrl`) are unchanged. Engine-only values
(`persistence`, `backup`, `secretKeys.internalSecret`,
`publicWorkspaceCreate`, `retention`, `mailbox`) are refused or ignored —
retention/mailbox are engine config compiled into the actor bundle, not
gateway env (see relaycast-repo changes).

```yaml
runtime:
  backend: terse-actors
  terseActors:
    gatewayImage:
      repository: ghcr.io/agentworkforce/relaycast-actors-gateway
      digest: ""                # REQUIRED sha256
    replicaCount: 1             # 1 until file blobs move to object storage
    controlPlaneUrl: ""         # default http://<release>-terse.<ns>.svc:7100
    existingSecret: ""          # REQUIRED; keys below
    secretKeys:
      apiKey: terse-api-key                  # == terse credentialsSecret api-key
      fileSigningSecret: relaycast-file-signing-secret
      credentialKeyring: relaycast-credential-keyring   # JSON keyring
    files:
      persistence: { existingClaim: "", storageClass: "", size: 10Gi }
      # future: files.objectStore: { bucket: "", prefix: "" }
```

Validation additions: `runtime.backend ∈ {sqlite, terse-actors}`;
`terse-actors` requires HTTPS `baseUrl` reachable from sandbox egress (forbid
`allowInsecureBaseUrl`), refuses sqlite-only blocks (`backup.enabled`,
non-null `retention`/`mailbox`, `publicWorkspaceCreate`, `internalSecret`
key requirement), keeps `networkPolicy` mandatory, and keeps ingress/gke
edge-deny semantics identical. `TERSE_ACTOR_URL` is set from
`controlPlaneUrl` (default derived); `TERSE_API_KEY`,
`RELAYCAST_FILE_SIGNING_SECRET`, `RELAYCAST_CREDENTIAL_KEYRING` come from the
mounted secret; `RELAYCAST_PUBLIC_URL = baseUrl`.

## Secrets

| Secret | Namespace | Keys | Used by |
| --- | --- | --- | --- |
| `credentialsSecret` (e.g. `terse-credentials`) | release ns | `postgres-url`, `jwt-signing-key` (base64 Ed25519 PKCS#8, stable), `api-key` | control-plane env |
| customer env secret (e.g. `relaycast-actor-env`) | `sandboxNamespace` | `RELAYCAST_PUBLIC_URL`, `RELAYCAST_FILE_SIGNING_SECRET` | injected into actor pods as `DURABLE_ACTORS_CUSTOMER_ENV`; **must carry label `terse.ai/customer-secret: "true"`** and be listed in the deployment's `secretRefs` |
| relaycast gateway `existingSecret` | release ns | `terse-api-key`, `relaycast-file-signing-secret`, `relaycast-credential-keyring` | gateway env |

Notes: the actor env secret lives in the *sandbox* namespace (control plane
reads it via its Role) while the file-signing value must equal the gateway's
— two copies by design; keep them in one ExternalSecret source. `api-key` is
the shared admin/invocation secret (`DURABLE_ACTORS_SECRET`) — the gateway
authenticates to the control plane with it, so it is deployment-admin
equivalent; egress to it should stay inside the cluster.

## NetworkPolicy

- Vendored chart already renders: sandbox-ns deny-by-default with ingress
  only from control-plane pods on 7101/7102, egress to control plane 7100,
  DNS, and public internet (needed for `storage.googleapis.com` and for actor
  calls to `baseUrl`). Control plane↔GCS and control plane↔Cloud SQL egress
  is unrestricted by that policy (it covers the sandbox ns only); rely on the
  cluster default or add a control-plane policy as a vendored patch.
- `charts/relaycast` netpol in terse-actors mode: ingress from release-ns
  pods + GFE ranges (unchanged); egress must allow the terse control-plane
  service and `publicUrl` (public LB egress — same shape the sandbox policy
  uses), plus DNS.

## Migration story (sqlite → terse-actors)

No upstream import tooling exists; treat `terse-actors` as a **fresh-install
backend** initially:

- Workspace data model differs fundamentally: sqlite = one DB holding many
  workspaces; actors = one SQLite per workspace actor. Migration means
  exporting each workspace's rows and replaying them into a new
  `Workspace` actor (via its engine API or a bespoke importer) and re-minting
  every credential as `ar_` — legacy `rk_`/`at_`/`nt_` credentials are
  refused by design on this backend (`restrictToArCredentials`; no
  `/v1/credentials/upgrade` endpoint).
- Practical path for existing installs: keep the sqlite release serving old
  workspaces read/write, stand up terse-actors alongside, migrate workspace
  by workspace behind the same `cast` host (cut over at the LB or in
  cloud-api routing), then retire the PVC. This is relaycast-repo migration
  tooling we do not have yet — **blocked**.
- Until then the chart should keep `sqlite` as the only permitted backend by
  default and gate `terse-actors` behind the new value plus the umbrella's
  `components.terseActors`, matching the existing "HA adapters must be
  proven in the engine first" stance — the engine side is now proven by the
  `examples/terse` proof; the chart side is what this doc defines.

## Required relaycast-repo changes (upstream, blocking)

1. **Gateway image.** Promote `examples/terse/gateway` to a published,
   digest-pinned image (`ghcr.io/agentworkforce/relaycast-actors-gateway`):
   Bun server + `@relaycast/engine/gateway` + `terse-sdk`; add `/healthz`,
   graceful shutdown, structured logs. Today it is example code only.
2. **Object-store file backend for `serveFile`** (GCS and/or S3-compatible),
   so file blobs survive pod loss and the gateway can run >1 replica.
   `SignedUrlFileStorage` already speaks signed URLs; only the serving side
   is disk-bound. Until then: PVC + 1 replica.
3. **Deploy mechanism for self-host.** The k8s provider requires a *compiled
   GCS bundle* (`durable-actors/v3/artifacts/{uuid}/…` in `artifactBucket`) +
   contract + `secretRefs`, registered via
   `PUT /v1/projects/{project}/deployment` with the admin api-key
   (`src/sandbox/gke.rs` refuses `localSource` on GKE: "compiled GCS code
   artifact required"). `terse deploy` (hosted terse-cli) doesn't target a
   self-hosted control plane, and the OSS `durable-actors` CLI has no remote
   deploy command. Needed: a small deployer (CI script or Job image) that
   runs the SDK compiler (`sdk/src/compiler` `bundleActor`/contract), uploads
   to `artifactBucket`, and PUTs the deployment with
   `secretRefs: [<actor env secret>]`. Until then, deploy is a manual runbook
   step after `helm install`.
4. **Realtime transport.** `/v1/node/ws` and `/v1/ws` over actor WebSockets
   (`prepareWebsocket` → control-plane `/v1/socket` bridge), plus a
   decision on `wait` semantics (returns immediately inside actors today).
   Required for feature parity with the sqlite backend; agents use the node
   transport by default.
5. **Workspace provisioning path.** The actor-mode entrypoint is anonymous
   `POST /v1/workspaces` via the gateway (snowflake + signed tag). There is
   no `/internal` admin API in actor mode (nothing holds a cross-workspace
   DB), and the edge-deny rules block public workspace create. Decide how
   `relay-cloud-api` (and the first-run flow) provisions workspaces: gate
   `POST /v1/workspaces` behind the existing internal-secret pattern at the
   gateway, or add a cloud-api-authenticated create path.
6. **Env contract, frozen and documented** (currently only in the example):

   | Process | Variables |
   | --- | --- |
   | gateway | `TERSE_ACTOR_URL` (control-plane origin; `DURABLE_ACTORS_CONTROL_PLANE_URL` equivalent), `TERSE_API_KEY` (`DURABLE_ACTORS_SECRET`), `RELAYCAST_FILE_SIGNING_SECRET`, `RELAYCAST_CREDENTIAL_KEYRING` (JSON), `RELAYCAST_FILE_DIR` or object-store config, `PORT` (8787) |
   | `Workspace` actor (via customer-env secret/`secretRefs`) | `RELAYCAST_PUBLIC_URL` (gateway public origin, embeds in signed file URLs), `RELAYCAST_FILE_SIGNING_SECRET` |
   | deployer | control-plane URL + api-key, artifact-bucket write creds |

7. **Engine config plumbing.** `retention.messageTtlDays`, `mailbox.*`,
   `maxUploadBytes` are `createActorRuntime({config})` inputs today
   (hardcoded 64 MiB upload cap in the example). Decide whether they remain
   baked into the actor bundle (rebuild to change) or arrive via customer
   env; chart values must match that choice.

## Implementable now vs blocked

Now (this repo, no relaycast changes):

- Vendor `charts/terse` at the pinned tag; add `components.terseActors` and a
  `terse` dependency to the umbrella; write the `values-gcp-proof`-style
  values for buckets/zones/GSA/credentialsSecret.
- Provision the GCP side from the proof scripts: 2 Rapid + 3 Standard
  buckets, GSA + Workload Identity binding `<ns>/<release>-terse`,
  `terse-credentials` secret, Cloud SQL database or direct postgres-url.
- Choose the actors edge (vendored Gateway vs umbrella gkeIngress host).

Blocked on relaycast-repo work:

- Everything under "Required relaycast-repo changes": gateway image,
  self-host deployer, file object store (for >1 replica), realtime
  WebSockets, workspace-provisioning auth story, env contract freeze.
- Therefore `runtime.backend: terse-actors` in `charts/relaycast` should land
  only once at least items 1, 3 and 5 exist; the umbrella can ship the terse
  subchart first so infra is exercised independently.

Open questions:

- Do we want actor pods' outbound webhook/A2A traffic egress-controlled
  further than "public HTTPS only" (the actor adapter already enforces public
  HTTPS URLs; sandbox netpol allows all public egress)?
- Single vs shared `api-key` between terse admin access and relaycast
  gateway auth — recommend one key now, revisit if we hand customer projects
  to anyone else.
- CapacityBuffer: keep off for the proof (requires GKE 1.35.2+ preview API);
  revisit for burst headroom.
