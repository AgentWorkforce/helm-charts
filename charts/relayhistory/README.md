# relayhistory

Maintained packaging of the Relay History Node runtime. The implementation is
derived from the upstream chart in `relayhistory-cloud`; that repository
remains the runtime source of truth.

The chart requires a digest-pinned image and `database.existingSecret` with
`DATABASE_URL` (least-privilege runtime role) and
`DATABASE_MIGRATIONS_URL` (migration owner). It creates no Secret and stores no
credential in values. PostgreSQL 17 with `vector` and `pg_trgm` is required.

Secrets are consumed through `valueFrom.secretKeyRef` environment variables,
not the file mounts used by the other charts in this repository, because the
experimental proof image reads credentials from the environment. This is a
known deviation from the file-mount convention to be resolved when the image
supports `*_FILE` variables.

The migration is a normal content-addressed Job, not a Helm hook, so it is
present under this repository's `--no-hooks` installation path. The operator
must wait for it to complete. The GCP proof uses one History replica and does
not claim HA.

### Write-hold migrations (two-step upgrade)

Some migrations need a write hold. With `migrations.allowWriteHold=true` the
migrate Job refuses while any runtime-role session is connected, so it cannot
succeed while the History Deployment is running, and `replicaCount` must stay 1.
Drain through values instead of scaling by hand:

1. Upgrade with both flags set. The Deployment renders with `replicas: 0` and
   the migrate Job runs against an idle database:

   ```sh
   helm upgrade <release> <chart> -n <ns> -f <your values> \
     --set relayhistory.migrations.allowWriteHold=true \
     --set relayhistory.migrations.drainForWriteHold=true
   kubectl -n <ns> wait --for=delete pod -l app.kubernetes.io/component=history --timeout=5m
   kubectl -n <ns> wait --for=condition=complete job -l app.kubernetes.io/component=migration --timeout=60m
   ```

   (Drop the `relayhistory.` prefix when installing this chart directly. Check
   your release's labels with `kubectl get job --show-labels`.) If the Job
   fails, stop: inspect its log before retrying, and do not run step 2.
2. Upgrade again with both flags back to `false` (the defaults). The Deployment
   returns to `replicaCount`. The migrate Job's pod template changes
   (`ALLOW_WRITE_HOLD=no`), so a new Job runs; it finds nothing to apply.

History is unavailable between the two steps. Take the recovery set described in
[`docs/selfhost-backup-restore.md`](../../docs/selfhost-backup-restore.md) before
step 1.

`networkPolicy.enabled` defaults to true with `allowAllEgress: false`, which
allows egress only to same-namespace pods and DNS. The external PostgreSQL
database (and any service URL outside the namespace) is then unreachable, so
the chart refuses to render until you either list it in
`networkPolicy.additionalEgress` (each rule with a non-empty `to`) or set
`allowAllEgress: true`, as the umbrella GCP profiles do.

The RelayHistory digest documented for the GCP proof is an experimental build,
not a released or supported RelayHistory artifact.

```sh
helm lint --strict charts/relayhistory \
  -f charts/relayhistory/ci/default-values.yaml
```
