# Self-hosted customer image and source inventory

Status: **blocked for customer release**.

The machine-readable source of this audit is
[`self-hosted/customer-images.yaml`](../self-hosted/customer-images.yaml).
The proof digests below are evidence, not approvals. The GCP conformance
Artifact Registry repository is not a customer distribution contract.
Separate chart-bundle licensing and notice gaps are recorded in
[`THIRD_PARTY_NOTICES.md`](../THIRD_PARTY_NOTICES.md); resolving an image row
does not resolve those packaging blockers.

## Scope and method

This inventory covers the full-customer GCP umbrella profile in
`charts/agent-relay/values-gcp-proof.yaml`, with all six product components
enabled. The chart was rendered with its known proof digests solely to inspect
Pod specs. It produces seven unique images because the Sessions migration Job
also runs a CloudNativePG PostgreSQL wait-for-role init container.

Images disabled by this profile are not active: MinIO (`locker.enabled=false`),
the OpenTelemetry collector (`otel.enabled=false`), the HoopDb Cluster, and
`alpine/k8s` for the three disabled privileged SQL Jobs.

The audit checked:

- chart values and rendered Deployment/Job container images;
- source repository visibility, exact commit availability, and repository
  license metadata;
- committed image workflows and the release runs recorded by the charts;
- registry manifests for platform coverage;
- proof build records and the source worktree state used by those builds.

Registry inspection of the proof images used the current operator's
credentials. It does not prove that a customer can pull them. Anonymous
inspection of the Sessions image returned `unauthorized`.

## Active inventory

| Image | Active use | Source and revision | License | Platforms | Release and customer path | Result |
| --- | --- | --- | --- | --- | --- | --- |
| `ghcr.io/agentworkforce/relaycast-self-host@sha256:a05732ad4f3614d057bb1460df40a30e3a9297c8930bfdda6d4e3d6dc9f41762` | Relaycast Deployment | [`AgentWorkforce/relaycast`](https://github.com/AgentWorkforce/relaycast) `bdf1b69ccaf1cd2bc7ce6c975c824907cc9eff49` | Apache-2.0 | Registry-verified `linux/amd64`, `linux/arm64` | Manual reviewed [workflow](https://github.com/AgentWorkforce/relaycast/blob/bdf1b69ccaf1cd2bc7ce6c975c824907cc9eff49/.github/workflows/publish-container.yml), [run](https://github.com/AgentWorkforce/relaycast/actions/runs/41161384835); public GHCR digest can be mirrored | Available |
| `ghcr.io/agentworkforce/relayauth@sha256:c23c92d25fdffef3b5838a1eef4c226925f859706365d9ccece229795b877288` | RelayAuth Deployment | [`AgentWorkforce/relayauth`](https://github.com/AgentWorkforce/relayauth) `784582ef983bb72b13b43512d9a4142ef5dfabb2` | Apache-2.0 | Registry-verified `linux/amd64`, `linux/arm64` | Reviewed [workflow](https://github.com/AgentWorkforce/relayauth/blob/784582ef983bb72b13b43512d9a4142ef5dfabb2/.github/workflows/container.yml), [run](https://github.com/AgentWorkforce/relayauth/actions/runs/41277442855), SBOM/provenance and anonymous-pull check; public GHCR digest can be mirrored | Available |
| `ghcr.io/agentworkforce/96bulls-services@sha256:6f22ea17dff336e1431664542759fd27958649388b90a0b2f0881883caa7c6b2` | Four Sessions Deployments and migration Job | Private [`AgentWorkforce/sessions-pipeline`](https://github.com/AgentWorkforce/sessions-pipeline) `7d7229bb31c121ecb98cd4e35c248fc2cf5669ad` | Unresolved; no repository license detected | Workflow expects both architectures; registry verification is blocked by anonymous `unauthorized` | Approval-gated [workflow](https://github.com/AgentWorkforce/sessions-pipeline/blob/7d7229bb31c121ecb98cd4e35c248fc2cf5669ad/.github/workflows/publish-image.yml) and [run](https://github.com/AgentWorkforce/sessions-pipeline/actions/runs/41375745173), but no customer entitlement/public promotion path | **Hard blocker** |
| `ghcr.io/cloudnative-pg/postgresql@sha256:ed6923f9ba2399cf9070379a353c710c29ced8a294be73986a2c3dae7e599ce3` | Sessions migration `wait-for-role` init container | Public [`cloudnative-pg/postgres-containers`](https://github.com/cloudnative-pg/postgres-containers); exact commit for this digest not recorded | Apache-2.0 | Registry-verified `linux/amd64`, `linux/arm64` | Public upstream digest; mirror after third-party review | Provenance review |
| `<private-proof-registry>/relayhistory@sha256:8fbda9bd89dd33994b6b3331fb403c38a25f04e6742050bd717e99661f3544ba` | RelayHistory Deployment and migration Job | Private [`AgentWorkforce/relayhistory-cloud`](https://github.com/AgentWorkforce/relayhistory-cloud) `4b5839f17c5e0cd481e92712c2a1a340a1604e73` | Unresolved; no repository license detected | Operator-verified `linux/amd64`, `linux/arm64` | Local proof build only; no container release workflow or approved customer channel | **Hard blocker** |
| `<private-proof-registry>/selfhost-api@sha256:0452a72da76d36c9c69ac6de75e51299b1df1a0fdfaec37831bff6deb55c7cf8` | Control API Deployment and migration Job | Private [`AgentWorkforce/cloud`](https://github.com/AgentWorkforce/cloud); no reproducible revision. The build tree was based on `b2d7b2d5781b8f601c19fbcbf0d495e40b217904`, but `packages/selfhost-api` was untracked and package manifests were modified. | Unresolved; no top-level license detected and no committed source snapshot | Operator-verified `linux/amd64` only | Local proof build only; no committed release workflow or approved customer channel | **Hard blocker** |
| `<private-proof-registry>/relay-dashboard@sha256:9bfc0c6b873411c7a0da60d746883bdef6aafd86a9b733c719500a603890b6fe` | Dashboard init and application containers | Public [`AgentWorkforce/relay-dashboard`](https://github.com/AgentWorkforce/relay-dashboard), but no reproducible revision. The build tree was based on `f71af3ee19683891e4774affa4cf9185c7cc7dba` with modified and untracked application, replay, Docker, and workflow files. | Apache-2.0 source; binary review blocked by missing exact source snapshot | Operator-verified `linux/amd64`, `linux/arm64` | Local proof build only; the base revision has CI only, not a container release workflow | **Hard blocker** |

`relay-dashboard` intentionally appears twice in the rendered Pod (an init
container copies static assets into a writable volume and the application
container serves them), but it is one unique image. Product migration Jobs
reuse their component image rather than adding another image.

## Customer acquisition and promotion

An image may enter customer values only after all of these gates pass:

1. Record an exact committed source revision and the Dockerfile/build context.
2. Approve source and binary distribution terms.
3. Build that revision in a reviewed workflow for every required Linux
   architecture. Emit and retain the digest, SBOM, provenance, vulnerability
   review, and workflow run.
4. Record product compatibility and support approval against that digest.
5. Publish to an approved public vendor repository or establish a documented
   customer entitlement. The proof Artifact Registry repository is not valid.
6. Copy `SOURCE@sha256:...` into the customer-owned registry by digest. Resolve
   and record the destination digest; do not assume cross-registry copies
   preserve it.
7. From the customer environment, verify pull authorization, platform
   manifests, signatures/provenance, SBOM, scan result, and runtime
   compatibility.
8. Set only the customer repository and immutable destination digest in the
   customer's values. Render and reject any proof registry, vendor-private
   package without entitlement, mutable tag, all-zero sentinel, or empty
   digest.

No one should retag a proof image and call that promotion. A customer release
must be rebuilt from reviewed committed source, except for an explicitly
approved byte-for-byte third-party mirror.

## Exact blockers

- `IMG-BLOCK-001` — **Sessions services**: GHCR denies anonymous access; no
  distribution license or supported customer entitlement/promotion procedure
  is recorded. Close by approving terms, establishing the customer channel,
  and verifying both required architectures.
- `IMG-BLOCK-002` — **RelayHistory**: the current artifact is explicitly
  experimental, its source license is unresolved, and there is no container
  release workflow or approved customer channel. The exact proof source commit
  is known, but that alone does not make the binary releasable.
- `IMG-BLOCK-003` — **Control API**: the digest cannot be reproduced from any
  commit because its package and Dockerfile were untracked when built. It is
  also amd64-only and lacks an approved license, workflow, and customer
  channel.
- `IMG-BLOCK-004` — **Dashboard**: the digest was built from a dirty source
  tree. Commit and review the exact application and container changes, then
  rebuild through an approved workflow and channel.
- `IMG-REVIEW-001` — **CloudNativePG PostgreSQL helper**: public, pinned,
  multi-arch, and Apache-2.0, but the digest-to-source revision and exact
  upstream release run are not recorded. This is a provenance review item, not
  a missing-public-image blocker.

Until `IMG-BLOCK-001` through `IMG-BLOCK-004` are closed, the umbrella chart is
not customer-image ready even if it renders or the proof cluster is healthy.
