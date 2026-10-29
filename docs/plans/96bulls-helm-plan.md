# 96Bulls Helm charts — plan (helm-chart-lead, 2026-10-28)

Status: PLAN ONLY. Nothing applied, merged, published or deployed. Every merge,
publish, deploy, credential or IAM change waits for Khaliq's explicit OK.

## 0. Verified facts (checked at source, not taken from the brief)

| Fact | Evidence |
|---|---|
| Alchemy `Kubernetes.HelmChart` runs `helm template --no-hooks`, applies with server-side apply, prunes dropped objects, keeps no Helm release | `@alchemy.run/kubernetes@2.0.0-beta.84` `lib/HelmChart.js:16-35` |
| Alchemy drift check treats a **missing object as drift** | `lib/HelmChart.js:215-219` (`missing:${key}`) |
| relayhistory migration Job + its ServiceAccount are `pre-install,pre-upgrade` hooks, so under Alchemy they are dropped and **migrations never run** | relayhistory-cloud#160 head, `charts/relayhistory/templates/migrate-job.yaml` |
| History `/readyz` checks only `SELECT 1` | `packages/relayhistory/src/node/server.ts:304-320` |
| History migration ledger is `sessions.__migrations` (name per file) | `scripts/check-write-hold.mjs:66-68` |
| History Job already has `activeDeadlineSeconds: 3600`, `rolloutBudgetSeconds: 600`, `allowWriteHold: false` | `charts/relayhistory/values.yaml:176-192` |
| relayauth#107 and relaycast#592: no hooks; SQLite on an RWO PVC, `replicas: 1`, `strategy: Recreate`; image defaults `relayauth:local` / `relaycast-self-host:local` | their `values.yaml`, `deployment.yaml` |
| relaycast PVC uses `helm.sh/resource-policy: keep`, which **Helm honors and Alchemy does not**: it prunes or destroys the PVC | `charts/relaycast/templates/pvc.yaml:9-10` |
| Cloud component chart is in flight in self-host-king's worktree: it has a plain-Job mode but still relies on the outer runner waiting and has no schema-ledger readiness (their gate G1 is RED). Its direct-Helm hook default is not the umbrella contract | self-host-king, 2026-10-28 |
| relayhistory-cloud has **two migration sets that cannot share a DB**: (a) `packages/relayhistory/db/migrations` (60 files, ledger `sessions.__migrations`, baked into the self-host image at `/app/db/migrations`); (b) `supabase/migrations` (session index + pipeline). PR #210's `20261025000600_pipeline_queue.sql` (`sessions.pipeline_jobs`) is in (b) only | `Dockerfile:28,35`; `migrate.ts:242`; #210 file list; 96-bulls-lead |
| HoopDb = set (b) + shim roles + 96bulls migrations (ledger `sessions.__96bulls_migrations`). The History chart (set a) must never point at HoopDb. **One runner per DB, so there is no ordering between charts** | 96-bulls-lead, 2026-10-28 |
| #210 (stage framework, PipelineQueue incl. Postgres SKIP LOCKED) and #211 (storage adapter, manifests/chunks routes, reconcile; stacked on #210) are open in relayhistory-cloud; #210 has no Postgres runner | `gh pr view 210/211`; infragrok |
| 96BullSessions: no commits yet; `src/hoopdb/migrate.ts` is already a hook-free, idempotent runner with ledger `sessions.__96bulls_migrations`; stage images are pinned in `stacks/local/topology.ts` | local checkout (96-bulls-lead's working tree) |
| helm-charts: only `release.yml` (chart-releaser v1.6.0, Helm v3.14.0, every push to main); no lint/kind CI; existing charts have no hooks | this repo @ 9c93fb2 |

## 1. Design rules for every chart we ship (the "Alchemy-safe" contract)

1. **No `helm.sh/hook` annotations.** CI fails if one appears in any chart (grep plus a `helm template --no-hooks` vs. plain diff).
2. **Migrations are a plain Job with an immutable, content-addressed name**:
   `<fullname>-migrate-<8 chars of sha256(image ref + migration config)>`.
   - Job `spec.template` is immutable, so patching an existing Job with a new image fails under SSA. A new name per image means Alchemy creates a new Job and prunes the old one.
   - **No `ttlSecondsAfterFinished`** under Alchemy: once the TTL deletes the Job, Alchemy reports it missing and recreates it, so the migration reruns. Keep the finished Job; make the TTL an opt-in value for plain-Helm users only.
   - The Job brings its own ServiceAccount as an ordinary object.
3. **Workloads gate on schema, not on Job ordering.** SSA applies everything at once, so the order of the rendered objects means nothing.
   - The app's `/readyz` returns 503 until the DB ledger contains every migration baked into the image (History: `sessions.__migrations` ⊇ image's `db/migrations`; 96Bulls: `sessions.__96bulls_migrations`).
   - Plus an optional `initContainer` `wait-for-schema`, using the same image and a `--check-schema` flag, so the pods never start serving early. Defaults: enabled; timeout = the Job's `activeDeadlineSeconds` (3600s for History).
   - `startupProbe` stays on `/healthz` so liveness never kills a pod that is waiting on a 60-minute migration.
4. **Write-hold migrations stay opt-in** (`migrations.allowWriteHold=false`). The Job fails loudly with the drain instructions it already prints. Document the Alchemy flow: scale to 0, set the flag, apply, unset.
5. **Cloud-agnostic defaults**: `image.repository` defaults to the public GHCR path (to be confirmed, see D3), not a GAR placeholder that is refused at render time. GKE/GAR/Cloud SQL proxy settings move to `examples/gke-values.yaml`. `ci/kind-values.yaml` must render and install with zero edits.
6. **PVC retention without Helm** (agreed with self-host-king): default to `existingClaim` (storage the customer pre-provisions) until an Alchemy-native retain/protect lifecycle is proven. `persistence.retainOnUninstall` does two things: it keeps the Helm annotation, and it lets the chart skip the PVC so Alchemy can own it outside the chart (`existingClaim`). Document that Alchemy ignores `resource-policy: keep`.
7. **No `randAlphaNum`/`lookup`/`genCA`** in templates: they reroll on every render and cause false drift. Secrets always come from `existingSecret`.
8. Security baseline already in #157/#107/#592: non-root, read-only rootfs, drop ALL, seccomp RuntimeDefault. Keep it.

## 2. Chart-by-chart

| Chart | Source | Work | Blocked on |
|---|---|---|---|
| **relayhistory** | relayhistory-cloud#157 + #160 | Convert migrate-job + SA to rule 2; add schema-aware `/readyz` and `--check-schema` (app change, upstream PR in relayhistory-cloud); move GKE/GAR to examples; default to a public image | #157/#160 landing; D3 image registry |
| **relayauth** | relayauth#107 | Hook-free already. Real default image; PVC rule 6; add startupProbe | #107 landing; D3 |
| **relaycast** | relaycast#592 | Hook-free already. Real default image; PVC rule 6 (it uses `resource-policy: keep`) | #592 landing; D3 |
| **96bulls-worker** | 96BullSessions `src/*` (one image `96bulls/services`, `SERVICE=` selects the entry point) | Components: `hoopdb-migrate` Job (rule 2, no TTL, advisory lock); `alleyoop-ingest` Deployment :8080 (`/healthz` startup+liveness, `/readyz` 503 until schema); `hoopdb-indexer` (replicas pinned to 1 until reconcile is leader-elected); `referee`; `bob-costas` (`BOB_COSTAS_MODEL=off`). `alleyoop-courier` is **not** in the chart (runs next to history.db). **Env contract is frozen to 96-bulls-lead's names**: HOOPDB_URL, LOCKER_ENDPOINT/BUCKET/REGION/ACCESS_KEY_ID/SECRET_ACCESS_KEY, TENANT_ORG_ID, WORKSPACE_ID, OTEL_EXPORTER_OTLP_ENDPOINT, DEPLOYMENT, DEPLOYMENT_ID; secret keys HOOPDB_URL, LOCKER_ACCESS_KEY_ID, LOCKER_SECRET_ACCESS_KEY (JWKS_JSON for local/kind only) | 96BullSessions first commit (gated by Khaliq); #210/#211 landing (vendored submodule pinned at #211 head 6f6d568) |
| **alleyoop** | 96BullSessions `src/alleyoop` | Folded into 96bulls-worker as `alleyoop-ingest`; there is no separate chart unless D5 says otherwise | D5 |
| **otel-collector** | upstream `open-telemetry/opentelemetry-collector` chart | **Do not write our own.** Ship a values file pinned to contrib 0.137.0 (matches topology.ts). Upstream has no hooks | — |
| **MinIO / CloudNativePG** | upstream charts | Values files plus pins, **not** wrapper charts. See §2a | Khaliq confirms pins |
| **96bulls (umbrella)** | new | Depends on relayhistory, relayauth, relaycast, 96bulls-worker (file:// in-repo); optional `cnpg-cluster` and `minio` toggles; one `global.image.registry`, `global.otel.endpoint` | All of the above |

### 2a. Proposed upstream pins (for Khaliq to confirm; versions are the latest in each repo index on 2026-10-28, checked by rendering each one with `helm template --include-crds`)

| Chart | Version (app) | Hooks | CRDs | Notes |
|---|---|---|---|---|
| `cloudnative-pg/cloudnative-pg` (operator) | 0.29.1 (1.30.1) | none | 11 | Install as its own Alchemy `HelmChart` **before** anything that renders a `Cluster` CR |
| `cloudnative-pg/cluster` | 0.9.0 | `test` only (dropped under `--no-hooks`, harmless) | 0 | Renders the `Cluster` CR. **Must verify** the chosen image has PG17 + `vector` + `pg_trgm` (History needs all three; HoopDb needs vector) before pinning `imageName` |
| `minio/minio` (charts.min.io) | 5.4.0 (RELEASE.2024-12-18) | **`post-install,post-upgrade`** (bucket/user setup Job) | 0 | The hook is dropped under Alchemy, so buckets never get created. Disable it and use our own `locker-init` Job (rule 2, `minio/mc`). The chart's app version is older than topology.ts's `RELEASE.2025-09-07`, so override `image.tag`. Check MinIO's community chart/image maintenance status before relying on it long-term (alternative: `minio-operator/operator` + `tenant` 7.1.1) |
| `open-telemetry/opentelemetry-collector` | 0.178.0 (0.163.2) | none | 0 | `mode: deployment`, `image.repository: otel/opentelemetry-collector-contrib`. Pin the image to topology.ts's 0.137.0 or bump both together |

Start with relayhistory: it is the only one with a real hook, and the readyz change is upstream app work that takes longest.

## 3. CI for AgentWorkforce/helm-charts (proposal)

New `lint.yml` on PRs (no publish):
- `ct lint` (chart-testing) plus `helm lint --strict` on changed charts; enforce a version bump.
- **hook ban**: fail on any `helm.sh/hook` under `charts/*/templates`.
- **render determinism**: render twice and diff; it must be byte-identical (rule 7).
- `kubeconform` on rendered output.
- **kind smoke**: `ct install` with `ci/kind-values.yaml` **and** an Alchemy-equivalent path (`helm template --no-hooks | kubectl apply --server-side`), then wait for Deployments Ready. This is the test that would have caught the hook problem.
- Snapshot tests (#157 already has `ci/snapshots/`; keep them).

`release.yml`: bump Helm to v4 (relayflows docs already assume it). Consider an OCI push to GHCR next to Pages (D4). Make the release job depend on lint passing on main.

Branch protection on main: require `lint.yml`, plus Khaliq review (README already says he gates merges).

## 4. Sequencing

1. (now, plan-only) Agree the contract in §1 with 96-bulls-lead and self-host-king.
2. Upstream PR in relayhistory-cloud: schema-aware readyz plus `--check-schema`. Independent of the chart move.
3. helm-charts PR A: `lint.yml` + hook ban + kind/SSA smoke, run on the existing relayfile/relayflows. No chart changes. Gated by Khaliq.
4. helm-charts PR B: relayhistory chart (converted). PR C: relayauth + relaycast. Each after its source PR lands and D1 is decided.
5. 96bulls-worker + umbrella, after 96BullSessions has a first commit and the Postgres runner lands.

## 5. Decisions for Khaliq

- **D1** Where charts live: move them into helm-charts (one repo, one CI, one Pages index), or keep each in its service repo and only publish from here. Recommend: move them in after their PRs land.
- **D2** 96BullSessions first commit and branch protection (owned with 96-bulls-lead).
- **D3** Public default image registry for self-host. self-host-king recommends **public GHCR**, with immutable release tags plus `repository@sha256` digest pinning in production, and optional `imagePullSecrets` passed to every workload and Job. Their Cloud component chart already does this. I agree.
- **D4** Add OCI publishing (GHCR) alongside GitHub Pages?
- **D5** Does alleyoop ship separately from the rest of the 96bulls services?

## 6. Open questions to peers

- infragrok: Alchemy call sites don't exist yet (they belong in 96BullSessions `stacks/`). Cross-chart migration ordering is **not needed** (separate DBs). Pins proposed in §2a. Open (Khaliq, unanswered): where should the 96BullSessions pipeline's Postgres queue runner live: in 96BullSessions, upstream in PR 210, or both?
- 96-bulls-lead: answered (separate DBs; component contract in §2). Open: does `/readyz` also check the 96bulls ledger (they plan to add it), and does `hoopdb-indexer` get leader election before replicas > 1?
- self-host-king: GHCR vs GAR for customer images (D3); PVC ownership under Alchemy (rule 6).

## 7. Decisions relayed by infragrok (2026-10-28 ~4:47 PM PT). NOT yet confirmed by Khaliq in this session

D1 move the charts into helm-charts · D2 the coding agent makes the first 96BullSessions commit and sets its branch protection · D3 public GHCR · D4 OCI push to GHCR through the helm-charts release workflow · D5 alleyoop ships as a separate chart. Pins in §2a approved (MinIO bucket hook off, plus our own init Job). Still open: where the 96BullSessions Postgres queue runner lives (96BullSessions, upstream PR 210, or both).
Correction relayed ~4:52 PM PT: **OpenSearch is not a requirement**; drop it. Observability: Khaliq's team uses PostHog and customers bring their own stack. The charts only ship an OTel exporter/collector (opentelemetry-collector 0.178.0). The runner question is still open.

Naming (relayed ~4:54 PM PT): refer to the pipeline as **96BullSessions**. "PR 210" means only the upstream code PR (it lives in the relayhistory-cloud repo).

Runner decision (relayed ~4:56 PM PT, final per infragrok): the Postgres queue runner runs in **both** 96BullSessions and upstream PR 210 while the migration is under way. relayhistory-cloud is the legacy pipeline and is still in use. After the migration, everything switches to 96BullSessions. Chart impact: 96bulls-worker is no longer blocked on PR 210. Open follow-up: during the overlap, do the two runners ever claim from the same `sessions.pipeline_jobs` table? SKIP LOCKED stops two runners claiming the same row, but it doesn't stop two different stage implementations handling the same stage type. Each runner should own its own DB, or its own set of stages.

Blocker reset (relayed ~5:00 PM PT; replaces every earlier list): nothing upstream blocks 96BullSessions. relayauth #107 and relaycast #592 are parallel tracks. relayhistory-cloud #157/#160 are legacy, not dependencies. Priority: 96BullSessions. The only timeline dependency is 96-bulls-lead's local stack (courier, Concourse seed, Alchemy local, smoke test).

## 8. kind smoke result (2026-10-28, local, `ci/96bulls/smoke.sh`)

GREEN. 96bulls-worker + alleyoop installed with `helm template --no-hooks | kubectl apply --server-side`, with no Helm release:
- the migrate Job completed (8 migrations)
- the locker-init Job retried until MinIO was up, then completed (so any apply order works)
- indexer, referee and bob-costas running; ingest `/readyz` 200 (schema-gated)
- re-applying the same render caused no Job conflict (content-addressed name)
- one transient indexer tick failure at startup, before MinIO was up, none since

Findings that change approved pins / need a decision:
- **D6 (new, for Khaliq): MinIO no longer publishes public images.** Both Chainguard (`cgr.dev/chainguard/minio@sha256:e70b2b1e…`, recommended by 96-bulls-lead; kind smoke GREEN, bucket created on first attempt) and pgsty pass on kind. Caveat: Chainguard's free tier is `:latest` only, so we pin a digest and must bump it ourselves for CVE fixes. `minio/minio` (Docker Hub) and `quay.io/minio/minio` are both missing, including 96BullSessions topology.ts's `RELEASE.2025-09-07` pin. The chart (minio 5.4.0) still works, but the image must come from elsewhere: `pgsty/minio` (community rebuild, `RELEASE.2026-08-04`, used for kind), Chainguard (latest-only on the free tier), or a different S3 (SeaweedFS/Garage) or the customer's own S3.
- **The OTel collector image must track the chart.** Chart 0.178.0 renders config that collector 0.137.0 rejects; use contrib 0.163.2 (the chart's appVersion). topology.ts pins 0.137.0, so it needs a bump.
- ESO: if 96bulls-worker and alleyoop share one existingSecret, enable `externalSecrets` in only one of them, or the two ExternalSecrets collide. The umbrella chart will own it.
