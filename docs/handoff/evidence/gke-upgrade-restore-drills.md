# GKE upgrade and backup/restore drills (2026-11-03)

Run in an isolated namespace and a dedicated Cloud SQL instance on the GKE
reference cluster, using the customer profile (`charts/agent-relay/values-gcp.yaml`,
all six components) plus a drill overlay for the drill's own database, bucket,
Pub/Sub and secrets. Internal identifiers are removed.

## Backup and isolated restore (agent-relay 0.1.1)
- `charts/agent-relay/scripts/gcp-recovery-backup.sh` with
  `REQUIRE_WRITES_QUIESCED=true`: writers scaled to zero for about 5 minutes.
  The script recorded `writesQuiesced: true` and `artifactsComplete: true`.
  The recovery set holds a Cloud SQL backup, one export per database (3),
  Retain snapshots of the Relaycast and RelayAuth PVCs, a copy of the sessions
  bucket, and the evidence, all in an archive bucket with a locked 35-day
  retention policy.
- The restore went into a new Cloud SQL instance, bucket, namespace and Helm
  release, with PVCs from imported snapshots and no Jobs rendered. All seven
  verification gates in `docs/selfhost-backup-restore.md` passed:
  - database migration ledgers match the source, and runtime and migration
    roles are still separate;
  - `PRAGMA integrity_check` returns `ok` for Relaycast and RelayAuth;
  - GCS object names, sizes and CRC32C match;
  - the known agents and DM are present, and a new two-agent ping and reply
    works;
  - the known session lists, replays and is found by search;
  - an identical delivery retry is idempotent;
  - cross-workspace access is denied, and nothing references production.
- RPO was 0 s, because writes were quiesced. RTO was 387 s to all pods Ready
  and 578 s to all gates passed; a cold restore is about 13 minutes. The
  targets are 15 minutes and 4 hours.
- Caveat: the first delivery-gate attempt failed because of a bug in the test
  harness, not the product. A rerun with a fresh marker passed, and all
  attempts are recorded.

## Pre-upgrade gate and upgrade (0.1.1 to the release candidate)
- `scripts/selfhost/pre-upgrade-check.sh` against the release-candidate chart (then versioned 0.3.0, before the upstream `96bulls` to `sessions-pipeline` chart rename that the published 0.3.1 also contains): OK
  (backup PASS, isolated restore PASS, migrations backward-compatible,
  side-by-side-restore rollback strategy, no active or failed Jobs).
- `helm upgrade` finished with all pods Ready in 23 s. No migration re-ran,
  and 17 of 17 post-upgrade checks passed: messaging, the control-plane org
  and workspaces, sessions list, replay and search, the sessions pipeline,
  cross-workspace denial, dashboard `/healthz` and `/runtime-config.js`, and
  service health.
- RelayHistory migrations: 47 files in the image, 47 ledger rows, and all 47
  checksums match.
- Partial against the release manifest: the dashboard ran the release image,
  and Relaycast and RelayAuth ran their release pins. The control-plane API
  ran its previous image, because the release package isn't public yet; its
  migrations are byte-identical to the release revision's. RelayHistory and
  Sessions ran pre-release images, because their release images aren't
  published yet.
- Not covered: the drill overlay kept the interim RelayAuth bearer opt-in on
  for session ingest.
