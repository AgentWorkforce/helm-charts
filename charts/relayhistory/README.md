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

The RelayHistory digest documented for the GCP proof is an experimental build,
not a released or supported RelayHistory artifact.

```sh
helm lint --strict charts/relayhistory \
  -f charts/relayhistory/ci/default-values.yaml
```
