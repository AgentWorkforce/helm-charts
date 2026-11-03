# Pre-upgrade evidence

Create three non-secret JSON files before running
`scripts/pre-upgrade-check.sh`. Keep credentials and Secret values out of all
evidence.

The backup evidence must describe a complete recovery set captured from the
currently deployed release while writes were quiesced:

```json
{
  "recoveryId": "ar-20261102T180000Z",
  "status": "PASS",
  "providerStatus": "SUCCESSFUL",
  "sourceRelease": "agent-relay",
  "sourceRevision": 7,
  "writesQuiesced": true,
  "artifactsComplete": true,
  "completedAt": "2026-11-02T18:10:00Z"
}
```

The restore evidence must identify the same recovery set and a completed
isolated restore:

```json
{
  "recoveryId": "ar-20261102T180000Z",
  "status": "PASS",
  "isolated": true,
  "allVerificationGatesPassed": true,
  "completedAt": "2026-11-02T19:00:00Z"
}
```

The compatibility evidence must match the deployed source revision and exact
reviewed target. `databaseMigration` is `backward-compatible` or
`forward-only`. `rollbackStrategy` is `database-restore` or
`side-by-side-restore`; Helm rollback is not a database recovery strategy.

```json
{
  "status": "PASS",
  "sourceRevision": 7,
  "targetChartVersion": "0.1.0",
  "databaseMigration": "forward-only",
  "rollbackStrategy": "side-by-side-restore",
  "reviewedAt": "2026-11-02T19:15:00Z"
}
```

By default, the gate accepts backup evidence up to 24 hours old, restore
evidence up to 720 hours old, and compatibility evidence up to 168 hours old.
Tighten these limits to match customer policy. The reviewed
`targetChartVersion` must match `helm show chart` for the gate's
`--target-chart`. A passing gate is evidence, not permission to mutate the
cluster or proof that a migration is reversible.
