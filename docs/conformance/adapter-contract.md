# Conformance adapter and hook contract

Product behavior is kept outside the chart harness because API paths and
authentication differ between installations. An adapter is an executable that
accepts one action argument, performs the assertion, and returns zero only when
the complete invariant passes. Standard output and error are discarded.

The harness supplies:

| Variable | Meaning |
| --- | --- |
| `CONFORMANCE_ACTION` | Action name, also passed as argument 1 |
| `CONFORMANCE_RUN_ID` | Unique fixture prefix |
| `CONFORMANCE_NAMESPACE` | Kubernetes target namespace |
| `CONFORMANCE_RELEASE` | Helm target release |
| `CONFORMANCE_BASE_URL` | Service URL, when configured |

Adapters must make fixtures unique using `CONFORMANCE_RUN_ID`, scope them to
disposable workspaces, and clean up where the product supports it. They must
not print credentials or response bodies.

## Required action semantics

`dedicated-role-denial`
: Authenticate as the dedicated restricted role. Attempt a privileged action
  and pass only on an authorization denial. Connectivity or authentication
  failure is not sufficient.

`two-agent-ping-reply`
: Create or select two agents in one disposable workspace, send a unique ping
  from A to B, produce B's reply, and read the correlated reply as A.

`desktop-bootstrap`
: Exercise the Desktop-origin bootstrap path rather than a generic API create.
  Verify origin metadata and that the bootstrapped identity can perform its
  first authorized operation.

`session-ingest-readback`
: Ingest a unique session with representative events, read it through the
  public read path, and compare identity, order, and content hashes.

`duplicate-receipt`
: Submit the same receipt identifier at least twice. Pass only when one logical
  receipt/side effect exists and both calls have the documented idempotent
  response behavior.

`cross-workspace-denial`
: Authenticate in workspace A and attempt to read a known object in workspace
  B. Pass only on an authorization/not-found denial with no object content.

`outbox-enqueue`
: Create a uniquely identified durable outbox item but do not acknowledge it as
  delivered. This action runs immediately before a deployment restart.

`outbox-recover`
: Wait for the queued item after restart. Pass only if it was delivered and
  acknowledged exactly once.

`network-policy-probe`
: From appropriate in-cluster probe identities, prove explicitly allowed
  traffic succeeds and explicitly denied traffic times out or is rejected.

`smoke`
: Verify the side-by-side previous-version release can serve a health check and
  perform a non-destructive authenticated read.

## Reference HTTP adapter

`scripts/conformance/http-adapter.sh` calls:

```text
POST <CONFORMANCE_BASE_URL>/api/conformance/v1/<action>
```

The prefix can be changed with `CONFORMANCE_API_PREFIX`. The request contains
the action, run ID, namespace, and release, but no credential. Authentication
can be provided with a restrictive curl config file:

```bash
export CONFORMANCE_CURL_CONFIG=/secure/path/conformance.curlrc
chmod 0600 "${CONFORMANCE_CURL_CONFIG}"
```

The endpoint must return a successful HTTP status and this minimal envelope:

```json
{"ok": true, "action": "two-agent-ping-reply"}
```

The adapter parses the response from a temporary mode-`0600` file and deletes
it. No response field is copied into harness evidence.

## Lifecycle hooks

Hooks are executable files and receive an action both as argument 1 and in
`CONFORMANCE_ACTION`. They receive the same run, namespace, and release
variables as adapters. Output is discarded.

Database outage hook:

- `begin`: make the isolated test database unavailable and return only after
  the outage is observable.
- `end`: restore it and return only after the database accepts connections.
- `end` must be idempotent because the exit trap can retry it.

Backup hook:

- `create`: start a backup, wait for completion, and validate provider status.
  Keep the backup identifier in hook-owned state keyed by the run ID.

Restore hook:

- `restore`: restore that run's backup into a new isolated database and
  namespace; never overwrite the source.
- `verify`: query the restored service and compare durable fixture hashes,
  counts, and tenant boundaries.

Hooks must reject namespaces that do not match their approved conformance
prefix. They must not call `kubectl get secret`, decode secret values, print
provider credentials, or write sensitive output to the evidence directory.
