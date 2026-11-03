# relay-cloud-api

Maintained packaging for `packages/selfhost-api` from the Cloud repository.
It provides the minimal self-host control API and does not package the full
Cloud/Next application.

`image.digest` and `existingSecret` are mandatory. The Secret keys are listed
in `values.yaml`; all values are mounted as files. The migration Job projects
only `database-migrations-url`; the API pod cannot read that key. The chart
never creates a Secret or renders credentials. Set `database.runtimeRole` to
the non-secret PostgreSQL role used by `database-url`; after migrations, the
owner grants that role runtime access only to `selfhost_*` application tables.

The image must contain the compiled `@cloud/selfhost-api` package. The server
runs `node node_modules/@cloud/selfhost-api/dist/server.js`; migrations run
`node node_modules/@cloud/selfhost-api/dist/migrate-cli.js`.
`services.relaycastUrl` and `services.relayhistoryUrl` are internal origins;
their `*PublicUrl` counterparts must be public HTTPS origins and are returned
to clients or used as the externally stable RelayHistory assertion audience.

The current runtime is deliberately one replica with `Recreate`: login/device
rate limiting remains process-local. This is a GCP proof shape, not HA.

`networkPolicy.enabled` defaults to true with `allowAllEgress: false`, which
allows egress only to same-namespace pods and DNS. The external PostgreSQL
database (and any service URL outside the namespace) is then unreachable, so
the chart refuses to render until you either list it in
`networkPolicy.additionalEgress` (each rule with a non-empty `to`) or set
`allowAllEgress: true`, as the umbrella GCP profiles do.

The migration is a normal deterministic Job because this repository installs
with `helm template --no-hooks`. An operator or reconciler must wait for it to
complete before considering a rollout successful; the API stays unready while
its database schema is unavailable.

```sh
helm lint --strict charts/relay-cloud-api \
  -f charts/relay-cloud-api/ci/default-values.yaml
```
