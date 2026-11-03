# Release status: what is proven and what is preview

Release: `agent-relay` chart 0.3.1 (OCI `oci://ghcr.io/agentworkforce/charts/agent-relay`,
version 0.3.1), 2026-11-03.

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
| Chart publication | The chart is published to GHCR as an OCI artifact from the `agent-relay-0.3.1` tag, with GitHub build-provenance attestation (`release-agent-relay.yml`). |
| End-to-end function on GKE | The reference GKE deployment passes all 15 end-to-end cases: single-org control plane, workspace isolation on 28 routes, session erasure, Relaycast messaging, the sessions API, admin env vars and audit, flows on an in-namespace worker, and the dashboard. See `docs/handoff/evidence/gke-e2e.md`. The harness is in `scripts/selfhost/`. |
| Upgrade and restore drills | An isolated GKE drill ran a quiesced backup, a restore into separate Cloud SQL, GCS, PVCs and namespace (all 7 verification gates PASS; RPO 0 s, RTO about 10-13 min), the pre-upgrade gate (OK), and an upgrade from 0.1.1 to the release candidate (17/17 checks PASS; run before the Sessions chart rename that the final 0.3.1 also contains). It is partial against the release images: the control-plane API, RelayHistory and Sessions ran pre-release images. See `docs/handoff/evidence/gke-upgrade-restore-drills.md`. |

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
- **Pending release images**: RelayHistory (its self-host runtime PR is held
  because merging deploys hosted production) and the attested Sessions
  services image (needs the owner's publish dispatch). Both stay REQUIRED
  OVERRIDE in `values-gcp.yaml`. The Relaycast image has no SBOM yet; its
  attested rebuild is held for the same reason. The control-plane API image
  is published but its package is not public yet.
- **Session ingest auth**: couriers need machine-bound History assertions. The
  interim RelayAuth bearer is refused unless the operator opts in
  (`ALLOW_INTERIM_RELAYAUTH_BEARER`), which the customer profile leaves off,
  and the drills did not test without it.
- **Dashboard API prefix**: the self-host dashboard only talks to the
  same-origin `/cloud/api` prefix (route `/cloud/api` and `/login` to the
  control-plane API).
- **Customer release gate**: `python3 scripts/release/validate-customer-release.py`
  fails closed on the items above. Its output is recorded with the release.
