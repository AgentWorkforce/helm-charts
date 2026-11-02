# Capacity hypotheses and load-test gates

## Supported workload profile

The `supported-100` profile is exactly:

- 100 distinct users;
- up to 50 concurrently connected agents;
- at least 10,000 successfully accepted sessions in each 24-hour test window.

The additive
[`values-gcp-supported-100.yaml`](../../charts/agent-relay/values-gcp-supported-100.yaml)
overlay contains initial pod and PVC sizing hypotheses. Apply it after
`values-gcp.yaml`. Its requests, limits, and storage sizes are not measured
capacity.

## Resource hypotheses

The initial hypothesis favors memory headroom and leaves replicas unchanged.
This is deliberate: `relaycast`, `relayauth`, and the control API currently
enforce single-writer or single-replica behavior, and the session indexer is
not leader-elected. Changing a replica count without application-level
conformance evidence would create a false HA claim.

Record these metrics per container during every capacity run:

- CPU usage and throttling;
- working-set memory, OOM kills, and restarts;
- request concurrency, open WebSockets, and connection churn;
- database pool use, wait time, connections, CPU, memory, IOPS, and storage;
- queue depth, oldest-item age, retry count, and dead letters;
- object-store request latency/error rate and bytes written;
- PVC used bytes/inodes and backup duration;
- ingest and search throughput, lag, and backlog-drain rate.

A passing run must keep CPU below 70% of requested cores averaged over any
15-minute window, memory working set below 80% of the limit, database
connections below 70% of the configured maximum, and persistent storage below
70% full. There must be no OOM kill, crash loop, unplanned restart, dropped
accepted work, or sustained CPU throttling above 10% of runnable time.
These are acceptance gates to test, not observations.

## Storage model

Use measured payload distributions from the release test; do not substitute
the examples below as benchmark data.

Let:

- `S` = accepted sessions/day (10,000 at the supported tier);
- `R` = retained days;
- `O95` = p95 object bytes stored per session;
- `D95` = p95 PostgreSQL bytes per session including indexes and TOAST;
- `M95` = p95 Relaycast message/file bytes attributable to a session;
- `H` = headroom factor, initially 1.5 until growth and compaction are measured;
- `B` = retained full-backup equivalents.

Plan minimum usable capacity as:

- object storage: `S * R * O95 * H`;
- PostgreSQL: `S * R * D95 * H`, plus WAL/PITR retention and maintenance
  workspace;
- Relaycast PVC: `S * R * M95 * H`;
- backup storage: measured protected bytes times `B * H`.

The overlay starts Relaycast at 50 GiB, RelayAuth at 5 GiB, and the Relaycast
backup PVC at 100 GiB. Those values are hypotheses. Before approval, replace
the formula inputs with measured p95 values, document retention, prove backup
completion within the 15-minute recovery-point cadence, and show at least 30%
free capacity after the 24-hour run and compaction.

For customer-managed Cloud SQL, enable storage growth and start with at least
the formula result; record machine class, storage type/size, IOPS behavior,
PITR/WAL retention, connection limit, and regional topology. For GCS, record
retention/lifecycle rules, object versioning, regional topology, and observed
growth. These provider settings are not encoded by the Helm chart.

## Workload and data requirements

The test manifest must record:

- generator revision and artifact digest;
- exact chart version and image-manifest digest;
- GKE, node, Cloud SQL, and GCS configuration;
- user, agent, and session counts;
- ramp, steady-state, burst, and soak duration;
- payload count/size distributions and file attachment mix;
- read/write/search operation mix and WebSocket reconnect rate;
- retention settings, initial database size, and any preloaded corpus;
- every fault injection and operator intervention.

Use deterministic seeds and synchronized clocks. Exclude generator failures
only when independently proven; retain raw generator logs either way.

## Required test phases

1. **Warm-up:** ramp from zero to 100 users and 50 connected agents over 30
   minutes. No readiness flapping or retry storm is allowed.
2. **Steady 24-hour run:** keep 50 agents connected, exercise all 100 users,
   and successfully accept at least 10,000 sessions. Run the documented read,
   search, dashboard, auth, and messaging mix throughout.
3. **Burst:** for 60 minutes, drive three times the steady-state session
   arrival rate while maintaining 50 connected agents. Three times is a
   planning hypothesis; record the actual achieved rate.
4. **Drain:** return to steady rate. Queue oldest age and searchable lag must
   return below their p95 thresholds within 15 minutes.
5. **Fault and recovery:** repeat representative traffic while restarting an
   application pod, disrupting one GKE node, and exercising database and
   object-store dependency failure modes that the selected topology supports.
6. **Restore drill:** restore into an isolated environment and measure the RPO
   and RTO definitions in the SLO document.

## Acceptance gates

Approval requires all of the following from one release-bound run:

- every availability journey is at least 99.9%;
- every latency and ingest-lag threshold passes;
- exactly-once-visible behavior checks find no duplicate visible delivery and
  no accepted session is lost;
- burst backlog drains within 15 minutes;
- all resource headroom gates pass;
- the 24-hour run has no unplanned restart or manual scaling/tuning;
- fault tests recover without accepted-work loss beyond the 15-minute RPO;
- the isolated restore demonstrates RPO at most 15 minutes and RTO at most 4
  hours;
- raw results, configuration, logs, and a SHA-256 artifact digest are retained.

Any configuration change after the run, including resource sizing, invalidates
the result for release approval unless a documented analysis shows it cannot
affect the measured path. No numeric throughput or latency claim may be copied
from this document into release material; only measured evidence may be used.
