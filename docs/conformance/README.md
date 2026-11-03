# Umbrella chart conformance harness

The harness in `scripts/conformance` validates an AgentWorkforce umbrella-chart
release without making changes by default. Audit mode performs read-only
Kubernetes checks and a Helm install dry-run. State-changing scenarios run only
when both `--apply` and the literal `--approval APPLY` are present.

The harness does not fetch, list, describe, decode, or persist Kubernetes
Secrets. Its wrappers reject Secret reads and Helm install/upgrade operations
that do not use `--hide-secret`. Tool output is discarded rather than copied
into evidence.

## Quick start

Run the local mocked tests first:

```bash
scripts/conformance/tests/run-tests.sh
```

Run an audit against an existing release:

```bash
scripts/conformance/run.sh \
  --chart oci://REGISTRY/agentworkforce \
  --current-version CURRENT \
  --previous-version PREVIOUS \
  --target-namespace agentworkforce \
  --target-release agentworkforce \
  --base-url https://relay.example.com \
  --dns-name relay.example.com \
  --values /secure/path/conformance-values.yaml
```

`--target-namespace` and `--target-release` name an existing release for
read-only audit checks only. Apply mode rejects them: state-changing scenarios
always run against isolated releases the harness creates.

Audit mode can validate rendering, client availability, existing
NetworkPolicy and GKE Ingress/certificate health, DNS, and TLS. Every state-changing scenario
is recorded as `PLAN`, not silently omitted.

After reviewing the audit evidence and fixture isolation, an authorized
operator can run the full suite:

```bash
scripts/conformance/run.sh \
  --apply --approval APPLY --cleanup \
  --chart oci://REGISTRY/agentworkforce \
  --current-version CURRENT \
  --previous-version PREVIOUS \
  --values /secure/path/conformance-values.yaml \
  --migration-failure-values /secure/path/migration-failure.yaml \
  --wrong-database-values /secure/path/wrong-database.yaml \
  --adapter scripts/conformance/http-adapter.sh \
  --base-url https://conformance.example.com \
  --dns-name conformance.example.com \
  --db-outage-hook /secure/path/db-outage-hook \
  --db-dependent-selector 'app.kubernetes.io/component in (api,history)' \
  --backup-hook /secure/path/backup-hook \
  --restore-hook /secure/path/restore-hook
```

Supplying `CONFORMANCE_APPROVAL=APPLY` is equivalent to
`--approval APPLY`, but `--apply` is still mandatory. `--cleanup` deletes only
namespaces created and tracked by the current run. Without it, test namespaces
remain available for diagnosis.

## Scenario coverage

| Scenario | Mechanism | Required configuration |
| --- | --- | --- |
| Fresh install | Isolated Helm install; Helm dry-run in audit mode | chart, current version |
| Previous-version upgrade | Install previous version, atomic in-place upgrade | previous version |
| Migration failure | Non-atomic upgrade that must fail on a migration Job, then explicit `helm rollback` that must restore the previous deployed release | previous version; migration-failure values |
| Wrong database | Require a known-bad DB fixture to leave started workloads unready | wrong-database values; a passing fresh install with the same base values as baseline |
| Dedicated-role denial | Product adapter assertion | adapter |
| Two-agent ping/reply | Product adapter assertion | adapter |
| Desktop-origin bootstrap | Product adapter assertion | adapter |
| Session ingest/read-back | Product adapter assertion | adapter |
| Duplicate receipt idempotency | Product adapter assertion | adapter |
| Cross-workspace denial | Product adapter assertion | adapter |
| DB outage readiness | Outage hook; pods matching `--db-dependent-selector` must go unready; recovery | outage hook; optional selector |
| Restart/outbox recovery | Queue fixture, rollout restart, exactly-once check | adapter |
| NetworkPolicy/GKE backend health | NetworkPolicy present, every GKE Ingress backend `HEALTHY`, every ManagedCertificate `Active`; optional traffic probe | target namespace (audit) or isolated release (apply); adapter for probe |
| DNS/TLS | Resolver and HTTPS/TLS 1.2+ health request | DNS name, HTTPS base URL |
| Backup | Backup hook | backup hook |
| Isolated restore | Restore then independent verification | restore hook |
| Side-by-side rollback | Previous version in a separate namespace plus smoke | previous version; adapter recommended |

`SKIP` means required operator configuration was absent. `PLAN` means the
scenario was intentionally blocked by audit mode. Neither is reported as a
failure, so release policy should separately define whether skips are allowed.

## Isolation and fixture requirements

- Use a dedicated GKE project or test cluster when exercising outage, backup,
  and restore behavior.
- The namespace prefix must be unique to the run. The harness labels namespaces
  it creates and records each one before cleanup.
- Failure values must point only to disposable test resources. Do not place
  credentials directly in values files; reference pre-provisioned resources
  using the chart's normal external-secret mechanism.
- The migration fixture must cause the current-version migration to fail after
  the previous version is healthy. The upgrade is deliberately not atomic, so
  the failed migration Job survives long enough to be attributed. The scenario
  passes only if a migration Job reached `Failed=True` with no unrelated image,
  config, or scheduling failures, and an explicit `helm rollback` then leaves
  the previous chart version deployed. Rollback restores Kubernetes resources
  only; the fixture database must be disposable.
- The wrong-database fixture must be a deliberately unreachable or incompatible
  test database. It must not identify a production database. The scenario is
  `SKIP` unless the fresh-install scenario passed in the same run with the same
  base values, so that a failure can be attributed to the wrong-database
  overlay.
- `--db-dependent-selector` (or `CONFORMANCE_DB_DEPENDENT_SELECTOR`) is the
  label selector for pods that must become unready during the database outage.
  The default is the release's `api` and `history` components
  (`app.kubernetes.io/instance=<release>,app.kubernetes.io/component in
  (api,history)`). Job pods are always excluded. The dashboard and
  SQLite-backed services are expected to stay ready, so do not include them.
- `CONFORMANCE_ROLLBACK_BASE_URL` can identify the ingress for the side-by-side
  previous-version release. If omitted, the adapter receives the main base URL.

The harness never provisions credentials. Pre-create service accounts,
workload identity bindings, DNS records, and TLS certificates through the
normal platform process.

## Evidence

The default output directory is:

```text
scripts/conformance/evidence/<run-id>/
```

Use `--evidence-dir` to send evidence to an approved ephemeral or CI artifact
location. Two files are emitted with mode `0600`:

- `evidence.jsonl`: one immutable event per scenario.
- `summary.json`: counts, overall success, timestamps, mode, and all events.

The schema identifier is `agentworkforce.conformance/v1`. Status is one of
`PASS`, `FAIL`, `SKIP`, or `PLAN`. Evidence contains scenario identifiers,
safe resource coordinates, exit codes, and summaries only. It contains no
command output, API response body, rendered manifest, values, token, or Secret
payload.

An example release gate that rejects failures and skips:

```bash
jq -e '
  .success == true
  and .counts.fail == 0
  and .counts.skip == 0
  and .counts.plan == 0
' scripts/conformance/evidence/RUN_ID/summary.json
```

## GKE resource expectations

The networking scenario checks the resources the charts actually deploy: a
GCE Ingress with a ManagedCertificate, whose health checks are derived from
readiness probes. The charts may also attach a `FrontendConfig`, but the
scenario does not validate it, and it does not look for `BackendConfig` or
`HealthCheckPolicy`. It passes only when:

- at least one `NetworkPolicy` exists in the namespace;
- at least one GCE Ingress exists, and each has an
  `ingress.kubernetes.io/backends` annotation in which every backend is
  `HEALTHY`; and
- every ManagedCertificate named by `networking.gke.io/managed-certificates`
  has `status.certificateStatus: Active`.

In apply mode, an adapter also receives `network-policy-probe` so the product
can prove allowed traffic succeeds and denied traffic fails. Presence alone is
useful audit evidence but is not a packet-level policy test.

## Safety properties

- Audit mode is the default.
- Mutation needs two independent command-line signals.
- Namespace and release names are validated before clients run.
- No shell `eval` is used.
- Kubernetes Secret resources and `.data`/`stringData` selectors are rejected.
- Helm install/upgrade must use `--hide-secret`.
- API and command response bodies are held in restrictive temporary files and
  deleted without entering evidence.
- Database outage recovery is retried from the exit trap if a run is
  interrupted after the outage begins.
- Cleanup is opt-in and constrained to namespaces created by the current run.
