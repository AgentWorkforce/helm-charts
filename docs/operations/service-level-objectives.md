# Service-level objectives

## Availability SLI

Measure each critical journey separately so a high-volume healthy endpoint
cannot hide a broken low-volume endpoint:

1. authenticate and refresh identity;
2. connect an agent and publish a Relaycast message;
3. deliver that message to an online recipient;
4. accept a session ingest request durably;
5. read and search an authorized session through RelayHistory;
6. load the dashboard and complete a control API request.

An eligible operation is a production request or synthetic attempt for one of
these journeys. Exclude health probes, operator/admin traffic, load-test
traffic, and requests rejected before application processing because they are
malformed or unauthorized. Count service-generated `408`, `429`, and every
`5xx`, timeout, reset, failed WebSocket handshake, duplicate visible delivery,
or missing delivery as bad. Customer-caused `4xx` responses other than `408`
and `429` are excluded. Publish and ingest are good only after the service has
reached the durability point promised by its API.

For journey \(j\):

`availability_j = good eligible operations_j / all eligible operations_j`

Every journey and the aggregate of all journeys must be at least 99.9% over
each calendar month. Missing telemetry is bad data for release approval; it
must not be silently excluded.

The monthly error budget is:

`budget_j = 0.001 * all eligible operations_j`

Budget consumption is:

`burn_j = bad eligible operations_j / budget_j`

No release may use unused budget from another journey or another month.
Planned maintenance consumes the budget because it affects the customer.

## Latency and ingest-lag release gates

The following are acceptance thresholds, not measured benchmark results.
Measure at the service edge, report p50/p95/p99 and sample count, and evaluate
each critical journey independently during the supported-tier load test.

| SLI | p95 gate | p99 gate | Measurement |
|---|---:|---:|---|
| Relaycast publish acknowledgement | 250 ms | 1 s | request accepted to durable acknowledgement |
| Online message delivery | 1 s | 5 s | publish accepted to recipient event received |
| Identity/control API | 500 ms | 2 s | edge receive to complete response |
| Session ingest acceptance | 500 ms | 2 s | edge receive to durable acceptance |
| RelayHistory authorized read/search | 1 s | 3 s | edge receive to complete response |
| Dashboard initial HTML | 1 s | 2 s | edge receive to complete HTML response |
| Session searchable lag | 60 s | 300 s | ingest acceptance to authorized search visibility |

In addition, no accepted session may remain unsearchable for more than 15
minutes during a passing test. The test must distinguish queueing lag from
clock skew and must use synchronized clocks.

## Recovery objectives

- **RPO:** at most 15 minutes. In a destructive restore drill, compare the
  latest committed source timestamp before the fault with the latest
  consistent record restored across PostgreSQL, Relaycast, RelayAuth, and
  object storage. The greatest verified data gap must be no more than 15
  minutes.
- **RTO:** at most 4 hours. Start the timer when the incident commander
  declares restore required. Stop only after all critical-journey probes pass
  continuously for 15 minutes and data consistency checks complete.

A backup job completing is not RPO evidence, and a pod becoming Ready is not
RTO evidence.
