# Self-hosted customer image and source inventory

Status: every image row is approved (agent-relay 0.3.10, audited
2026-11-04). The customer release gate stays blocked on the non-image items
in [`docs/handoff/STATUS.md`](handoff/STATUS.md).

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

`values-gcp.yaml` pins all seven by digest, and every one is public on GHCR
(anonymous pull verified for both platforms).

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
| `ghcr.io/agentworkforce/96bulls-services@sha256:070fe6fd46ecd1e1f9db32ff22379f6df9b9e6c4d48ede5312c8fb986a95f3a9` | Four Sessions Deployments and migration Job | [`AgentWorkforce/sessions-pipeline`](https://github.com/AgentWorkforce/sessions-pipeline) `main` `f1c2672581b6f88d26d0549b4d1cb78fce0d5f16` (origin-bound courier assertions, #204) | Apache-2.0 | Registry-verified anonymously, `linux/amd64`, `linux/arm64` | Approval-gated [workflow](https://github.com/AgentWorkforce/sessions-pipeline/blob/f1c2672581b6f88d26d0549b4d1cb78fce0d5f16/.github/workflows/publish-image.yml), [run](https://github.com/AgentWorkforce/sessions-pipeline/actions/runs/41796259208); SBOM and max-mode provenance (the GitHub attestation step failed on the private repository); public. Its first migrate needs the HoopDb role bootstraps shipped in the image (see the agent-relay 0.3.10 release notes) | Approved |
| `ghcr.io/cloudnative-pg/postgresql@sha256:ed6923f9ba2399cf9070379a353c710c29ced8a294be73986a2c3dae7e599ce3` | Sessions migration `wait-for-role` init container | Public [`cloudnative-pg/postgres-containers`](https://github.com/cloudnative-pg/postgres-containers) `4c2710a78328becdadf708ca6d9cb3fb61f3f5ee` (the image's revision label and its SLSA provenance both name it) | Apache-2.0 packaging; PostgreSQL License | Registry-verified `linux/amd64`, `linux/arm64` | Upstream [`bake_targets.yml`](https://github.com/cloudnative-pg/postgres-containers/blob/4c2710a78328becdadf708ca6d9cb3fb61f3f5ee/.github/workflows/bake_targets.yml), [run 40291448784](https://github.com/cloudnative-pg/postgres-containers/actions/runs/40291448784); SPDX SBOM and SLSA v1 attestation manifests; keyless cosign signature verified with `--certificate-github-workflow-sha 4c2710a…` | Approved (third party) |
| `ghcr.io/agentworkforce/relayhistory@sha256:d3166bb14e1d6043426a4dd8cc05408b94574c8d79ad5fd6e789e0de00ab371b` | RelayHistory Deployment and migration Job | [`AgentWorkforce/relayhistory-cloud`](https://github.com/AgentWorkforce/relayhistory-cloud) `main` `53c333349cb9210832013cd3a2423f5f19062d36` | Apache-2.0 | Registry-verified anonymously, `linux/amd64`, `linux/arm64` | Reviewed [workflow](https://github.com/AgentWorkforce/relayhistory-cloud/blob/53c333349cb9210832013cd3a2423f5f19062d36/.github/workflows/container.yml), [run](https://github.com/AgentWorkforce/relayhistory-cloud/actions/runs/41773941051); SBOM and max-mode provenance (the GitHub attestation step failed on the private repository); public | Approved |
| `ghcr.io/agentworkforce/selfhost-api@sha256:95c7877741054dc2f1cafa26be3faa9bfe4660ed85d637aef4524daa10481963` | Control API Deployment and migration Job | [`AgentWorkforce/relaycontrol`](https://github.com/AgentWorkforce/relaycontrol) `main` `9b80b04c64fc33778a4a197cbcec16f1038c30ae` (0.3.0) | Apache-2.0 | Registry-verified anonymously, `linux/amd64`, `linux/arm64` | Reviewed [workflow](https://github.com/AgentWorkforce/relaycontrol/blob/9b80b04c64fc33778a4a197cbcec16f1038c30ae/.github/workflows/release-selfhost-api-image.yml), [run](https://github.com/AgentWorkforce/relaycontrol/actions/runs/41799800818); SBOM and max-mode provenance; public | Approved |
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

None for images. `IMG-BLOCK-001` and `IMG-BLOCK-005` (Sessions services),
`IMG-BLOCK-002` (RelayHistory) and `IMG-BLOCK-003` (control API) were closed
in agent-relay 0.3.10: each release image is public on GHCR, built by a
reviewed workflow from a recorded `main` revision with an SBOM and max-mode
provenance, and both platforms were verified anonymously. Relaycast was
closed in agent-relay 0.3.3 by the attested 12.7.0 digest.
