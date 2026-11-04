# Self-hosted customer image and source inventory

Status: **blocked for customer release** (agent-relay 0.3.8, audited
2026-11-03; images unchanged since 0.3.3).

The machine-readable source of this audit is
[`self-hosted/customer-images.yaml`](../self-hosted/customer-images.yaml); this
page summarizes it, and the manifest wins if they ever disagree. Recorded
digests are evidence, not approvals. The GCP proof Artifact Registry
repository is not a customer distribution contract. Separate chart-bundle
licensing and notice gaps are recorded in
[`THIRD_PARTY_NOTICES.md`](../THIRD_PARTY_NOTICES.md); resolving an image row
does not resolve those packaging blockers.

## Scope and method

This inventory covers the full-customer GCP umbrella profile in
`charts/agent-relay/values-gcp.yaml`, with all six product components
enabled. It produces seven unique images because the Sessions migration Job
also runs a CloudNativePG PostgreSQL wait-for-role init container.

`values-gcp.yaml` pins five of them by digest. The Sessions services and
RelayHistory release images are not published, so the profile renders a zero
digest for both (REQUIRED OVERRIDE). Their rows below record the last audited
private or proof digest as evidence; the profile does not render those
digests, and the release gate reports the mismatch.

Images disabled by this profile are not active: MinIO (`locker.enabled=false`),
the OpenTelemetry collector (`otel.enabled=false`), the HoopDb Cluster, and
`alpine/k8s` for the three disabled privileged SQL Jobs. Durable actors,
Relayfile and Relayflows are optional components, off in this profile, and are
not part of this matrix.

The audit checked:

- chart values and rendered Deployment/Job container images;
- source repository, exact commit, and license;
- the release workflow and run that built each digest;
- registry manifests for platform coverage;
- SBOM and provenance attestations, and signatures where published.

## Active inventory

| Image | Active use | Source and revision | License | Platforms | Release and supply chain | Result |
| --- | --- | --- | --- | --- | --- | --- |
| `ghcr.io/agentworkforce/relaycast-self-host@sha256:81274dca7ab58673383dc7a9c777f422f29606c7422e81b5ea15724770f1455e` | Relaycast Deployment | [`AgentWorkforce/relaycast`](https://github.com/AgentWorkforce/relaycast) `bf713d86b366b46f491e287ce6117c7c5ff1f27a` | Apache-2.0 | Registry-verified `linux/amd64`, `linux/arm64` (anonymous) | [Workflow](https://github.com/AgentWorkforce/relaycast/blob/bf713d86b366b46f491e287ce6117c7c5ff1f27a/.github/workflows/publish-container.yml), [run](https://github.com/AgentWorkforce/relaycast/actions/runs/41717074565). SPDX SBOM, max-mode provenance, GitHub build-provenance attestation. Public GHCR digest | Approved |
| `ghcr.io/agentworkforce/relayauth@sha256:c23c92d25fdffef3b5838a1eef4c226925f859706365d9ccece229795b877288` | RelayAuth Deployment | [`AgentWorkforce/relayauth`](https://github.com/AgentWorkforce/relayauth) `784582ef983bb72b13b43512d9a4142ef5dfabb2` | Apache-2.0 | Registry-verified `linux/amd64`, `linux/arm64` | [Workflow](https://github.com/AgentWorkforce/relayauth/blob/784582ef983bb72b13b43512d9a4142ef5dfabb2/.github/workflows/container.yml), [run](https://github.com/AgentWorkforce/relayauth/actions/runs/41277442855); SBOM and provenance; anonymous pull verified | Approved |
| `ghcr.io/agentworkforce/96bulls-services@sha256:6f22ea17dff336e1431664542759fd27958649388b90a0b2f0881883caa7c6b2` (evidence only; the profile renders a zero digest) | Four Sessions Deployments and migration Job | Private [`AgentWorkforce/sessions-pipeline`](https://github.com/AgentWorkforce/sessions-pipeline) `7d7229bb31c121ecb98cd4e35c248fc2cf5669ad` | Apache-2.0 by owner decision; the LICENSE landed on `main` in #172 (merge `51b38ff`), after this revision | Not registry-verified (anonymous inspection returns `unauthorized`) | Approval-gated [workflow](https://github.com/AgentWorkforce/sessions-pipeline/blob/7d7229bb31c121ecb98cd4e35c248fc2cf5669ad/.github/workflows/publish-image.yml), [run](https://github.com/AgentWorkforce/sessions-pipeline/actions/runs/41375745173); no SBOM, min-mode provenance. The attested release image is **not published** | **Hard blocker** (`IMG-BLOCK-001`, `IMG-BLOCK-005`) |
| `ghcr.io/cloudnative-pg/postgresql@sha256:ed6923f9ba2399cf9070379a353c710c29ced8a294be73986a2c3dae7e599ce3` | Sessions migration `wait-for-role` init container | Public [`cloudnative-pg/postgres-containers`](https://github.com/cloudnative-pg/postgres-containers) `4c2710a78328becdadf708ca6d9cb3fb61f3f5ee` (the image's revision label and its SLSA provenance both name it) | Apache-2.0 packaging; PostgreSQL License | Registry-verified `linux/amd64`, `linux/arm64` | Upstream [`bake_targets.yml`](https://github.com/cloudnative-pg/postgres-containers/blob/4c2710a78328becdadf708ca6d9cb3fb61f3f5ee/.github/workflows/bake_targets.yml), [run 40291448784](https://github.com/cloudnative-pg/postgres-containers/actions/runs/40291448784); SPDX SBOM and SLSA v1 attestation manifests; keyless cosign signature verified with `--certificate-github-workflow-sha 4c2710a…` | Approved (third party) |
| `<private-proof-registry>/relayhistory@sha256:8fbda9bd89dd33994b6b3331fb403c38a25f04e6742050bd717e99661f3544ba` (evidence only; the profile renders a zero digest) | RelayHistory Deployment and migration Job | Private [`AgentWorkforce/relayhistory-cloud`](https://github.com/AgentWorkforce/relayhistory-cloud) `4b5839f17c5e0cd481e92712c2a1a340a1604e73` | Apache-2.0 by owner decision; the LICENSE PR (#279) is open and held, so no revision carries it yet | Operator-verified `linux/amd64`, `linux/arm64` | Local proof build; no reviewed container release workflow or customer channel. The release image is **not published** | **Hard blocker** (`IMG-BLOCK-002`) |
| `ghcr.io/agentworkforce/selfhost-api@sha256:535e6718fa239ce87dead3d22e7c53324bed44bfcef94018918e8804d24af478` | Control API Deployment and migration Job | [`AgentWorkforce/relaycontrol`](https://github.com/AgentWorkforce/relaycontrol) `main` `8e989a1b1842179f775906091777ce50a9f78ecd` | Apache-2.0 | Built for `linux/amd64`, `linux/arm64`; not registry-verified while the package is private | Reviewed [workflow](https://github.com/AgentWorkforce/relaycontrol/blob/8e989a1b1842179f775906091777ce50a9f78ecd/.github/workflows/release-selfhost-api-image.yml), [run](https://github.com/AgentWorkforce/relaycontrol/actions/runs/41684552871); SBOM and max-mode provenance. The GHCR package is **private** | **Hard blocker** (`IMG-BLOCK-003`) |
| `ghcr.io/agentworkforce/relay-dashboard@sha256:bbeca872c7e204a02a17050db6ac6309c6d36a07bcd00e1da3a739923f990282` | Dashboard init and application containers | [`AgentWorkforce/relay-dashboard`](https://github.com/AgentWorkforce/relay-dashboard) `main` `b2134062c28c9526032b23a731aac4d681fe8689` | Apache-2.0 | Registry-verified anonymously, `linux/amd64`, `linux/arm64` | Reviewed [workflow](https://github.com/AgentWorkforce/relay-dashboard/blob/b2134062c28c9526032b23a731aac4d681fe8689/.github/workflows/container.yml), [run](https://github.com/AgentWorkforce/relay-dashboard/actions/runs/41697933750); SPDX SBOM, max-mode provenance and a GitHub build-provenance attestation; public | Approved |

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

- `IMG-BLOCK-001` — **Sessions services**: the image is private and has no
  approved customer acquisition or promotion procedure. The attested release
  image (from `main` at or after the LICENSE merge `51b38ff`) needs the
  owner's publish dispatch. Close by publishing it to a customer-readable
  channel and verifying both required architectures.
- `IMG-BLOCK-002` — **RelayHistory**: the recorded artifact is an experimental
  proof image with no reviewed container release workflow or customer channel.
  The self-host runtime PR and the LICENSE PR are held. Close with a reviewed
  release workflow that publishes from the recorded commit, and promotion
  evidence.
- `IMG-BLOCK-003` — **Control API**: source and release are canonical
  (relaycontrol `main` `8e989a1`, SBOM and max-mode provenance), but the GHCR
  package is still private, so customers have no pull path. Close by making
  the package public and verifying both platforms anonymously.
- `IMG-BLOCK-005` — **Sessions services**: the recorded digest predates the
  attested workflow (sessions-pipeline #172). Close with a rebuild that
  publishes an SBOM and signed provenance, and record the new digest.
  Relaycast was closed in agent-relay 0.3.3 by the attested 12.7.0 digest.

Until these are closed, the umbrella chart is not customer-image ready even if
it renders or the proof cluster is healthy.
