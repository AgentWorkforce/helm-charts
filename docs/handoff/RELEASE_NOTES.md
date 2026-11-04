# Agent Relay self-hosted GCP handoff

Customer handoff for the requested **Helm charts + agent prompts**.

## Artifacts

`scripts/package-customer-handoff.sh build --output-dir <dir>` produces, for
one source revision:

- `agent-relay-customer-handoff-<rev12>.tar.gz`
- `agent-relay-customer-handoff-<rev12>.zip` (identical content)
- `SHA256SUMS` covering both archives

No release workflow publishes these files. The release owner uploads all three,
unchanged, to the agreed delivery channel and gives the customer the full
source revision so they can match it against `RELEASE-MANIFEST.json`. A
`-DEVELOPMENT-PREVIEW` or `-INCOMPLETE` archive must never be delivered as a
customer release.

Each archive unpacks to `agent-relay-customer-handoff/` and contains:

- the `agent-relay` umbrella chart and its leaf charts as source (run
  `helm dependency build` at install time), with the structural
  `values-gcp.yaml` example;
- the reusable `setting-up-self-hosted-agent-relay-gcp` setup skill;
- the reference architecture, image supply chain, backup/restore runbook,
  conformance contract, and license docs;
- read-only verification, pre-upgrade, release-validation, and conformance
  scripts;
- `RELEASE-MANIFEST.json` and an inner `SHA256SUMS`.

See [`HANDOFF.md`](HANDOFF.md) for the full layout and verification steps.

The charts cover Relaycast, RelayAuth, Sessions Pipeline, RelayHistory, the
headless control-plane API (relaycontrol), Relay Dashboard, and custom-origin
Desktop setup. Relayflows, durable actors and Relayfile are optional preview
components, off by default. Billing, provider integrations and hosted fleet
are out of scope.

## agent-relay 0.3.4 (2026-11-03): documentation patch, pending publication

Published from the `agent-relay-0.3.4` tag
(`oci://ghcr.io/agentworkforce/charts/agent-relay`, version 0.3.4); it is not
available until that tag's release workflow succeeds. The relaycast leaf chart
is 0.3.3 and the relayauth leaf chart is 0.1.3. Both drop the stale
instruction to override the Relaycast `image.digest` for `ar_` credentials:
the pinned default (engine 12.7.0) already satisfies the `>=12.3.x`
requirement. The `values-gcp.yaml` credentials comment says the same. Images,
templates and the rendered `values-gcp.yaml` are unchanged from 0.3.3, so the
image matrix below still applies.

## agent-relay 0.3.3 (2026-11-03)

Published from the `agent-relay-0.3.3` tag. Pins the attested Relaycast image:
`relaycast-self-host@sha256:81274dca…` (relaycast main `bf713d86`, engine
12.7.0; SPDX SBOM, max-mode provenance and a GitHub build-provenance
attestation; public, amd64+arm64). The relaycast leaf chart is 0.3.2 with the
same default. This image has not run the GKE upgrade/restore drills; its kind
smoke runs in this repository's CI. It also carries the untagged 0.3.2 GKE
proof-overlay refresh (proof values only). Everything else is as in 0.3.1.

Images in `charts/agent-relay/values-gcp.yaml` (0.3.3 and 0.3.4). Only the
Relaycast row differs from 0.3.1:

| Component | Image | Source | Supply chain |
|---|---|---|---|
| Control-plane API | `ghcr.io/agentworkforce/selfhost-api@sha256:535e6718…` | relaycontrol `8e989a1` | SBOM + max provenance; **private package, not pullable by customers yet** (installation blocker) |
| Dashboard | `ghcr.io/agentworkforce/relay-dashboard@sha256:bbeca872…` | relay-dashboard `b213406` | SBOM + max provenance + GitHub attestation; public |
| RelayAuth | `ghcr.io/agentworkforce/relayauth@sha256:c23c92d2…` | relayauth `784582e` | SBOM + provenance; public |
| Relaycast | `ghcr.io/agentworkforce/relaycast-self-host@sha256:81274dca…` | relaycast `bf713d86` (engine 12.7.0) | SBOM + max provenance + GitHub attestation; public |
| Sessions wait-for-role | `ghcr.io/cloudnative-pg/postgresql@sha256:ed6923f9…` | upstream `4c2710a` | as in 0.3.1 |
| Sessions services | `ghcr.io/agentworkforce/96bulls-services` | no release revision yet | **not published** (zero digest); REQUIRED OVERRIDE, installation blocker |
| RelayHistory | `ghcr.io/agentworkforce/relayhistory` | relayhistory-cloud | **not published** (zero digest); REQUIRED OVERRIDE, installation blocker |

## agent-relay 0.3.1 (2026-11-03): reviewable release

This is the first release of the umbrella chart, published from the
`agent-relay-0.3.1` tag (`oci://ghcr.io/agentworkforce/charts/agent-relay`,
version 0.3.1). It is meant
for review by a company evaluating self-hosted Agent Relay on GCP. It is a
`portable-single` preview, not an HA or production-readiness claim, and the
handoff archive is labelled a development preview because the fail-closed
customer release gate does not pass yet. **[STATUS.md](STATUS.md)** lists
what is proven, what is preview, and what is planned.

Images in `charts/agent-relay/values-gcp.yaml`. Five images are pinned by
immutable digest. Four of them (dashboard, RelayAuth, Relaycast, PostgreSQL)
are public; mirror those to your registry by digest. The control-plane API
(`selfhost-api`) package is still private, so customers cannot pull it yet;
it blocks installation until the package is public. The
Sessions services and RelayHistory images are not published: they render a
zero digest (REQUIRED OVERRIDE) and block installation until a release image
exists and you pin it.

| Component | Image | Source | Supply chain |
|---|---|---|---|
| Control-plane API | `ghcr.io/agentworkforce/selfhost-api@sha256:535e6718…` | relaycontrol `8e989a1` | SBOM + max provenance; **private package, not pullable by customers yet** (installation blocker) |
| Dashboard | `ghcr.io/agentworkforce/relay-dashboard@sha256:bbeca872…` | relay-dashboard `b213406` | SBOM + max provenance + GitHub attestation; public |
| RelayAuth | `ghcr.io/agentworkforce/relayauth@sha256:c23c92d2…` | relayauth `784582e` | SBOM + provenance; public |
| Relaycast | `ghcr.io/agentworkforce/relaycast-self-host@sha256:a05732ad…` | relaycast `bdf1b69` | public; **no SBOM, min-mode provenance only** (attested rebuild pending; closed in 0.3.3) |
| Sessions wait-for-role | `ghcr.io/cloudnative-pg/postgresql@sha256:ed6923f9…` | upstream `4c2710a` | upstream revision label `4c2710a`, run 40291448784; SBOM + SLSA attestation manifests; keyless cosign signature verified with `--certificate-github-workflow-sha` |
| Sessions services | `ghcr.io/agentworkforce/96bulls-services` | no release revision yet (last audited private image: `7d7229b`; the release is to be built from `main` at or after `51b38ff`) | **not published** (zero digest): the attested publish needs the owner's dispatch; REQUIRED OVERRIDE, installation blocker |
| RelayHistory | `ghcr.io/agentworkforce/relayhistory` | relayhistory-cloud | **not published** (zero digest): the self-host runtime PR is held; REQUIRED OVERRIDE, installation blocker |

Full revisions, release runs, platforms and blockers are in
`self-hosted/customer-images.yaml`.

Changes since the unreleased 0.2.x/0.3.0 profiles (0.3.0 renamed the `96bulls:` values key to `sessions-pipeline:`):

- `values-gcp.yaml` pins the five release images above by digest instead of
  placeholders (`selfhost-api` is still private). Sessions services and RelayHistory keep zero-digest
  placeholders (REQUIRED OVERRIDE).
- `values-gcp.yaml` sets `sessions-pipeline.alleyoop.auth.issuer` to RelayAuth's issuer
  and asks for `historyOrigin` (REQUIRED OVERRIDE; it must equal
  `relayhistory.relayauth.historyOrigin`, and the chart refuses to render when
  they differ). The chart default (`https://96bulls.local`)
  rejected every RelayAuth-signed courier assertion.
- The self-host dashboard image talks only to the same-origin `/cloud/api`
  prefix. Keep `relay-dashboard.runtime.apiBasePath` at `/cloud/api` and route
  `/cloud/api` and `/login` to the control-plane API, as the GKE ingress does.
- Session ingest from Desktop couriers needs machine-bound History assertions.
  The generic RelayAuth bearer is refused unless an operator opts in to the
  interim `ALLOW_INTERIM_RELAYAUTH_BEARER` setting, which is off in the
  customer profile.
- The handoff now includes the end-to-end harness (`scripts/selfhost/e2e-gcp-proof.sh`,
  `--secret` is now required) and sanitized GKE evidence summaries
  (`docs/handoff/evidence/`).
