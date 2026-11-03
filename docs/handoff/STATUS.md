# Release status: what is proven and what is preview

Release: `agent-relay` chart __CHART_VERSION__ (OCI `oci://ghcr.io/agentworkforce/charts/agent-relay`,
version __CHART_VERSION__), 2026-11-03.

This release is for **review by a company evaluating a self-hosted Agent Relay
on GCP**. It is a reviewable, digest-pinned, `portable-single` release. It is not
a production-readiness or high-availability claim. The fail-closed customer
release gate (`scripts/release/validate-customer-release.py`) does **not** pass
yet. The items it still reports are listed under "Not yet done; planned" below.
This archive is therefore labelled a development preview.

## Proven

| Area | Evidence |
|---|---|
| Licensing | Every first-party image repository is Apache-2.0 at the image source revision. The chart repository is Apache-2.0. The third-party PostgreSQL image (CloudNativePG) is Apache-2.0 packaging. See `self-hosted/customer-release-evidence.json` (`licenses.firstParty`). |
| Image supply chain | Each image is built by its repository's release workflow from a reviewed commit on `main` and pushed to `ghcr.io/agentworkforce/*` with an SBOM and max-mode provenance. Revisions, runs, digests and platforms are in `self-hosted/customer-images.yaml`. |
| Chart publication | The chart is published to GHCR as an OCI artifact from the `agent-relay-__CHART_VERSION__` tag, with GitHub build-provenance attestation (`release-agent-relay.yml`). |
| End-to-end function on GKE | The reference GKE deployment passes all 15 end-to-end cases: single-org control plane, workspace isolation on 28 routes, session erasure, Relaycast messaging, the sessions API, admin env vars and audit, flows on an in-namespace worker, and the dashboard. See `docs/handoff/evidence/gke-e2e.md`. The harness is in `scripts/selfhost/`. |
| Upgrade and restore drills | __DRILL_SUMMARY__ |

## Preview (shipped as documentation, not in the release matrix)

- **Relaycast on durable actors** (gateway plus durable-actors control plane):
  proven on GKE (`docs/handoff/evidence/gke-durable-actors-preview.md`), but its
  chart change is unmerged and its control-plane patch is not upstream. It is
  not in this chart version or image manifest.
- **Relayflows in-cluster** (`components.relayflows`, off by default): see
  `docs/self-hosted-relayflows.md`.

## Not yet done; planned

These gate items are open. None of them is claimed.

- **Branch and environment controls**: the chart repository has no branch
  protection or protected release environment yet. The gate records
  `release.branchControls` / `environmentControls` as unprotected.
- **Operational readiness** (`supported-100`: 100 users, 50 concurrent agents,
  10,000 sessions/day): the 24-hour soak, burst, drain and fault phases in
  `docs/operations/capacity-and-load-test.md` have not run. Alerts, dashboards
  and runbooks evidence are not produced. No SLO or capacity claim is made.
- **Version compatibility** (server N and N-1 x Desktop current and previous): not
  run. This is the first published server chart.
- **Desktop**: the custom-origin Desktop (self-hosted sign-in) passes CI on
  macOS arm64/x64, Linux x64/arm64 and Windows (relay-desktop CI run
  41606660810), but it is not merged or released yet.
- **High availability**: Relaycast and RelayAuth are single-writer SQLite
  workloads on RWO volumes.
__EXTRA_GAPS__
