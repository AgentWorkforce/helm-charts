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

## agent-relay 0.3.0 (2026-11-03): reviewable release

This is the first published release of the umbrella chart
(`oci://ghcr.io/agentworkforce/charts/agent-relay`, version 0.3.0). It is meant
for review by a company evaluating self-hosted Agent Relay on GCP. It is a
`portable-single` preview, not an HA or production-readiness claim, and the
handoff archive is labelled a development preview because the fail-closed
customer release gate does not pass yet. **[STATUS.md](STATUS.md)** lists
what is proven, what is preview, and what is planned.

Images in `charts/agent-relay/values-gcp.yaml` (all by immutable digest; mirror
them to your registry by digest):

| Component | Image | Source | Supply chain |
|---|---|---|---|
| Control-plane API | `ghcr.io/agentworkforce/selfhost-api@sha256:535e6718…` | relaycontrol `8e989a1` | SBOM + max provenance; package visibility pending |
| Dashboard | `ghcr.io/agentworkforce/relay-dashboard@sha256:bbeca872…` | relay-dashboard `b213406` | SBOM + max provenance + GitHub attestation; public |
| RelayAuth | `ghcr.io/agentworkforce/relayauth@sha256:c23c92d2…` | relayauth `784582e` | SBOM + provenance + attestation; public |
| Relaycast | `ghcr.io/agentworkforce/relaycast-self-host@sha256:a05732ad…` | relaycast `bdf1b69` | public; no SBOM yet (attested rebuild pending) |
| Sessions wait-for-role | `ghcr.io/cloudnative-pg/postgresql@sha256:ed6923f9…` | upstream `4c2710a` | upstream SBOM + SLSA provenance + verified cosign signature |
| Sessions services | `ghcr.io/agentworkforce/96bulls-services` | sessions-pipeline main | **pending**: the attested publish needs the owner's dispatch; REQUIRED OVERRIDE until pinned |
| RelayHistory | `ghcr.io/agentworkforce/relayhistory` | relayhistory-cloud | **pending**: the self-host runtime PR is held; REQUIRED OVERRIDE until pinned |

Full revisions, release runs, platforms and blockers are in
`self-hosted/customer-images.yaml`.

Changes since the unreleased 0.2.0 profile:

- `values-gcp.yaml` pins the release images above instead of placeholders.
- `values-gcp.yaml` sets `96bulls.alleyoop.auth.issuer` to RelayAuth's issuer
  and asks for `historyOrigin`. The chart default (`https://96bulls.local`)
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
