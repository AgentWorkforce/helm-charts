# Release status: what is proven and what is preview

Release: `agent-relay` chart 0.3.4, 2026-11-03. **Pending publication**: it
will be published to `oci://ghcr.io/agentworkforce/charts/agent-relay` version
0.3.4 by the `agent-relay-0.3.4` tag's release workflow
(`release-agent-relay.yml`), and is not available until that run succeeds. 0.3.4 is a documentation patch
of 0.3.3 (the Relaycast `ar_` credentials guidance); images, templates and the
rendered `values-gcp.yaml` are unchanged.

Published versions of the umbrella chart:

| Version | Tag | Notes |
|---|---|---|
| 0.3.1 | `agent-relay-0.3.1` | First published version. Relaycast `a05732ad…` (no SBOM, min-mode provenance). |
| 0.3.3 | `agent-relay-0.3.3` | Pins the attested Relaycast image `81274dca…` (engine 12.7.0) and the GKE proof-overlay refresh. 0.3.2 was never tagged. |
| 0.3.4 | `agent-relay-0.3.4` (to be pushed) | Pending publication (see above); not pullable until the tag's release run succeeds. |

This release is for **review by a company evaluating a self-hosted Agent Relay
on GCP**. It is a reviewable `portable-single` release that pins every
published image by digest; the RelayHistory and Sessions services images are
not published and stay REQUIRED OVERRIDE. It is not
a production-readiness or high-availability claim. The fail-closed customer
release gate (`scripts/release/validate-customer-release.py`) does **not** pass
yet. The items it still reports, and the blockers it does not check, are listed
under "Not yet done; planned" below.
This archive is therefore labelled a development preview.

## Proven

| Area | Evidence (what was checked, including its limits) |
|---|---|
| Licensing | Apache-2.0 at `main` for relaycast, relayauth, relaycontrol (control-plane API), relay-dashboard and this chart repository. Sessions Pipeline is Apache-2.0 by owner decision; its LICENSE landed on `main` in sessions-pipeline #172 (merge `51b38ff`), after the image revision recorded in the manifest (`7d7229b`). RelayHistory is Apache-2.0 by owner decision; its LICENSE PR (relayhistory-cloud #279) is open and held, so no RelayHistory revision carries it yet. The third-party PostgreSQL image (CloudNativePG) is Apache-2.0 packaging. See `self-hosted/customer-release-evidence.json` (`licenses.firstParty`). |
| Image supply chain | Mixed; per image in `self-hosted/customer-images.yaml`. The control-plane API (`selfhost-api`) and dashboard images were built by their release workflows from reviewed `main` commits with an SBOM and max-mode provenance (the dashboard also has a GitHub build-provenance attestation and is public; the `selfhost-api` package is still private). The RelayAuth image has an SBOM and provenance. Since 0.3.3 the Relaycast image (`81274dca…`, relaycast `bf713d86`, engine 12.7.0) also has an SBOM, max-mode provenance and a GitHub build-provenance attestation, and is public. The CloudNativePG PostgreSQL digest is verified against upstream revision `4c2710a` (run 40291448784, SBOM and SLSA attestation manifests, keyless cosign signature verified with `--certificate-github-workflow-sha`). The Sessions services and RelayHistory release images are **not published**; both stay REQUIRED OVERRIDE (zero digest) in `values-gcp.yaml`. |
| End-to-end function on GKE | The live proof deployment (not the 0.3.1 or later customer profile: it ran the experimental RelayHistory proof image, and Relaycast on durable actors in the final run) passed all 15 end-to-end cases: single-org bootstrap, Relaycast messaging, session delivery and reads, workspace isolation on 28 routes, restart durability, RelayAuth verification, the Sessions Pipeline, session erasure, public-edge checks, the sessions API, admin env vars and audit, flows on an in-namespace worker, the dashboard and cleanup. See `docs/handoff/evidence/gke-e2e.md`. The harness is in `scripts/selfhost/`. |
| Upgrade and restore drills | An isolated GKE drill of agent-relay 0.1.1 ran a quiesced backup (writers stopped for 314 s) and a restore into a separate Cloud SQL instance, bucket, PVCs and namespace. All seven recorded verification gates passed (Cloud SQL, Relaycast and RelayAuth integrity, GCS integrity, isolated messaging, cross-workspace denial, no production references). No data was lost between the quiesce point and the capture. RTO was 387 s to pods Ready and 578 s to the gates passing; a cold restore adds about 189 s of instance creation (about 767 s, about 12.8 min). The pre-upgrade gate passed (OK), and an upgrade from 0.1.1 to the release candidate passed 17/17 checks (run before the Sessions chart rename that the final 0.3.1 also contains). Neither ran the full release image set: the restore ran the 0.1.1 drill images, and the upgrade ran previous or live-proof images for `selfhost-api`, RelayHistory and Sessions. See `docs/handoff/evidence/gke-upgrade-restore-drills.md`. |

## Preview (optional, off by default, not in the customer image matrix)

- **Relaycast on durable actors** (gateway plus durable-actors control plane):
  the chart (since 0.3.1) includes the optional `durable-actors` dependency
  (`components.durableActors`, off by default) and
  `relaycast.runtime.backend=durable-actors`. Its images and profile are not
  part of the gated customer image matrix (`self-hosted/customer-images.yaml`),
  and the invoke-only control-plane patch the proof used is not upstream. It
  was proven on GKE with 4 known Relaycast end-to-end suite failures
  (`docs/handoff/evidence/gke-durable-actors-preview.md`).
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
  run (server N is 0.3.4, N-1 is 0.3.3).
- **Desktop**: the custom-origin Desktop (self-hosted sign-in) passes CI on
  macOS arm64/x64, Linux x64/arm64 and Windows (relay-desktop CI run
  41606660810), but it is not merged or released yet.
- **High availability**: Relaycast and RelayAuth are single-writer SQLite
  workloads on RWO volumes.
- **Pending release images**: RelayHistory (its self-host runtime PR is held
  because merging deploys hosted production) and the attested Sessions
  services image (needs the owner's publish dispatch). Both stay REQUIRED
  OVERRIDE in `values-gcp.yaml`. The control-plane API image is published
  but its package is not public yet. (The Relaycast image is closed: since
  0.3.3 it is the attested 12.7.0 build, see "Image supply chain" above.)
- **Session ingest auth**: couriers need machine-bound History assertions. The
  interim RelayAuth bearer is refused unless the operator opts in
  (`ALLOW_INTERIM_RELAYAUTH_BEARER`), which the customer profile leaves off,
  and the drills did not test without it.
- **Sessions Pipeline to RelayHistory durable runtime bridge**: recorded as
  not implemented on 2026-11-02. This release does not re-verify it, and the
  release gate does not check it. It stays an installation blocker until the
  bridge is implemented and verified end to end.
- **Chart publication of 0.3.4**: to be published to GHCR as an OCI artifact
  from the `agent-relay-0.3.4` tag, with a GitHub build-provenance attestation
  (`release-agent-relay.yml`). Pending until that tag's run succeeds. 0.3.1
  and 0.3.3 are already published the same way.
- **Release evidence bound to this manifest**: the gate also rejects evidence
  that was recorded against other images. The upgrade and restore drills ran
  other image sets than `self-hosted/customer-images.yaml` (and the restore
  ran chart 0.1.1). The RelayHistory migration evidence is for the live-proof
  image (relayhistory-cloud `74a6e526`), not the manifest's revision. The
  manifest's RelayHistory and Sessions rows record the last audited proof or
  private digests, which `values-gcp.yaml` does not render (it renders zero
  REQUIRED OVERRIDE digests).
- **Dashboard API prefix**: the self-host dashboard only talks to the
  same-origin `/cloud/api` prefix (route `/cloud/api` and `/login` to the
  control-plane API).
- **Customer release gate**: `python3 scripts/release/validate-customer-release.py`
  fails closed on the gate items above; the archive includes the structured
  evidence in `self-hosted/customer-release-evidence.json`.
