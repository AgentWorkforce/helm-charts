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

## agent-relay 0.3.8 (unreleased): first boot, sign-in and invites

To be published from the `agent-relay-0.3.8` tag (not tagged yet). It
supersedes the never-tagged 0.3.7 and includes its changes. It ships with
relay-cloud-api 0.2.4.

- **First-boot bootstrap.** Set `relay-cloud-api.bootstrap.{orgName,adminEmail}`
  together with `secretKeys.relaycastInternalSecret` and `dashboardUrl`. On
  first start the API:
  - creates the organization;
  - makes the admin email its owner;
  - creates a `Default` workspace bound to a new Relaycast workspace.

  It is idempotent, so it is safe on an existing install.
- **Sign-in.** `auth.oidc` adds OpenID Connect with PKCE (Google Workspace,
  Okta, Entra ID, Keycloak). The client secret goes in
  `secretKeys.oidcClientSecret`. Optional `auth.emailLink` sends single-use
  email sign-in links and needs `smtp`. The bootstrap token remains the
  operator break-glass.
- **Invites.** Owners and admins invite from Settings → Members:
  - links are single use and expire after `auth.inviteTtlHours`;
  - they are emailed when `smtp` is set and can always be copied;
  - `auth.autoJoinDomains` lets a domain join without invites.
- `values-gcp.yaml` carries a commented example.

Requirements:
- a selfhost-api image from relaycontrol #13 or later;
- a dashboard image from relay-dashboard #92 or later, for the invite UI.

The `relay-cloud-api` and `relay-dashboard` digests pinned in `values-gcp.yaml`
predate both, so override `relay-cloud-api.image.digest` and
`relay-dashboard.image.digest` with images built from those revisions (or
later) until the pins move. Otherwise the new values render but the API ignores
them and Members has no invite UI.

With none of these values set, renders are byte-identical apart from the
`helm.sh/chart` labels.

## agent-relay 0.3.7 (2026-11-04): proof overlay patch

To be published from the `agent-relay-0.3.7` tag (not tagged yet). 0.3.7 is
a GKE proof-overlay and documentation patch of 0.3.6:
`values-gcp-proof-live.yaml` sets `relay-dashboard.customerProfile.desktop`
(`urlScheme`, `siteUrl`) for the proof's custom Desktop build, and the
relay-dashboard chart (0.1.3) documents `customerProfile.desktop`. The
dashboard's "Connect your agents" link uses it with a dashboard image from
relay-dashboard #88 or later. Templates, images and `values-gcp.yaml` are
unchanged from 0.3.6; renders differ only in the `helm.sh/chart` labels
(and `DASHBOARD_CUSTOMER_PROFILE` in the gcp-proof-live render).

## agent-relay 0.3.6 (2026-11-04): single-host mode and dashboard branding

Published from the `agent-relay-0.3.6` tag
(`oci://ghcr.io/agentworkforce/charts/agent-relay`, version 0.3.6; release run
41769269329). 0.3.5 was
never tagged; its changes ship here. The leaf charts are relay-cloud-api 0.2.2
and relay-dashboard 0.1.2.

- **Single-host mode** (opt-in, `global.singleHost.host`, off by default). The
  dashboard and the control-plane API share one host (`/`, `/cloud/api`,
  `/login`, `/api`): relay-cloud-api derives its `publicUrl` and the dashboard
  derives `runtime.publicUrl` and `ingress.host` from it, and the GKE Ingress
  drops the `api.` host. Relaycast, Relay History, Relayfile and
  durable-actors keep their own hosts (see the agent-relay README "Single-host
  mode" and `values-single-host-example.yaml`).
- **Enterprise branding.** The new optional `relay-dashboard.customerProfile`
  (product name and title, light and dark logos, favicon, accent and primary
  button colors, a support link, and the "Powered by Agent Relay" line) is
  rendered into `DASHBOARD_CUSTOMER_PROFILE` and served in
  `/runtime-config.js`, so a customer brand needs no per-customer image, but
  it requires a dashboard image built from relay-dashboard `8eac2bd` or later
  (see below). It is empty by default; `values-gcp.yaml` carries a commented
  example, and the relay-dashboard README documents every field.
- **Sessions sidebar facets** (dashboard image). Picking a project or harness
  no longer collapses the sidebar to that option. Each facet's options and
  counts ignore its own selection and respect the other filters, and a
  project is sent to the server only as an exact project id.

Branding and the facet fix need a dashboard image built from relay-dashboard
`8eac2bd` or later. The customer profile's pinned dashboard digest predates it:
it ignores `customerProfile` and keeps the earlier sessions sidebar until a
new release image is published and pinned. With single-host mode off and no
`customerProfile`, every default render is byte-identical to 0.3.4 apart from
the `helm.sh/chart` labels; images are unchanged from 0.3.4.

## agent-relay 0.3.4 (2026-11-03): documentation patch

Published from the `agent-relay-0.3.4` tag
(`oci://ghcr.io/agentworkforce/charts/agent-relay`, version 0.3.4). The relaycast leaf chart
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
