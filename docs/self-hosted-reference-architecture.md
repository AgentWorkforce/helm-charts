# Self-hosted reference architecture

Status: implementation kickoff. This document distinguishes released behavior
from planned adapter work; it is not evidence that the HA profiles exist.

## Product shape

The self-hosted product is composed rather than monolithic.

| Layer | Default | Responsibility |
|---|---:|---|
| Relaycast portable-single | Off in `charts/self-hosted` until `addons.relaycast=true`. Installing `charts/relaycast` 0.2.0 directly is the same explicit baseline | Agent communication, REST/WebSocket API, messages, presence, actions, and files. One replica, Recreate, SQLite, ReadWriteOnce. Not HA |
| Identity/control plane | Required for the complete product; naming and package boundary unresolved | Sign-in and tokens, organizations, workspaces, device enrollment, discovery, deployment bindings, and dashboard |
| Relayflows | Off | Durable, resumable, or scheduled multi-step workflow execution |
| Relayfile/providers | Off. Not a dependency of `charts/self-hosted` or `charts/relaycast`, and not on the AWS hot path. Inclusion in the self-host product is unresolved | GitHub, Slack, and other provider write-backs |
| 96Bulls | Off | Session capture, durable storage, indexing, summaries, and evaluation |
| Observer/UI | Off | Human inspection and operations surfaces |

An add-on may consume core APIs, but the core availability path must never
depend on an add-on. In particular, Relaycast does not require Relayflows.

## Runtime profiles

### `portable-single` — implemented

`charts/relaycast` runs the released self-host image with its Node adapters,
one SQLite database, and local file storage on a retained persistent volume.
The chart enforces one replica and `Recreate` upgrades. This is a useful local,
edge, and small-team profile, not an HA cloud claim.

### `aws-ha` — next conformance target, not a chart

No Helm chart or values profile implements this. The six missing proofs are
frozen in [aws-ha-gates.md](aws-ha-gates.md). The Relaycast engine must own the
HA adapter implementation before a chart may select it. The working
adapter boundary discussed with Barry and kjgrok is:

- relational state: PostgreSQL (Aurora/RDS on AWS);
- realtime fan-out and ephemeral coordination: Redis pub/sub (ElastiCache);
- durable asynchronous delivery: a queue adapter (SQS);
- files and signed object operations: an object-store adapter (S3);
- runtime selection: one explicit backend setting, consumed by the runtime;
- deployment binding: workspace-to-Relaycast target resolution in the control
  plane, without hard-coded hosted gateway URLs.

Helm may select a released backend and wire endpoints, identity, and Secrets.
It must not duplicate engine behavior or imply an adapter exists before the
runtime and conformance suite prove it.

### `gcp-ha` — after the AWS contract is frozen

GCP must implement the same committed adapter contract using Cloud SQL for
PostgreSQL, Memorystore for Redis, Pub/Sub for durable asynchronous delivery,
and Cloud Storage for objects. Provider differences belong behind adapters and
in deployment values, not in Relaycast API behavior.

If GCP requires a core API or semantic change after the AWS pattern is frozen,
that is evidence the boundary is incomplete and must be corrected explicitly,
not hidden in chart conditionals.

## Proof and commit gates

The sequence is deliberate:

1. Prove the released `portable-single` chart locally and on Kubernetes.
2. Implement adapter ports and the HA runtime in Relaycast, including its
   provider-neutral conformance suite.
3. Prove `aws-ha` end to end on EKS with the AgentWorkforce charts.
4. Review the evidence, then commit/freeze the adapter pattern and its
   conformance contract.
5. Implement and prove `gcp-ha` against that same contract.

AWS proof is complete only when evidence covers:

- fresh install and idempotent upgrade;
- workspace creation/claim, agent registration, REST, and WebSocket delivery;
- multi-replica fan-out without duplicate or lost visible events;
- file upload, download, expiry, and cleanup through object storage;
- queue retry, dead-letter behavior, replay, and recovery after worker loss;
- database, Redis, pod, and availability-zone failure/recovery exercises;
- backup and restore with an explicit recovery point and recovery time;
- metrics, logs, traces, alerts, and operator runbooks;
- a 96Bulls session flowing through ingest, Locker, HoopDB, summaries, and
  verdicts when that add-on is enabled;
- add-ons independently disabled without breaking the Relaycast core;
- no AWS-specific branches in provider-neutral engine behavior.

## Unresolved decisions

Do not encode these as defaults until the product owners resolve them:

- RelayAuth-to-RelayIdentity rename and repository/package timing;
- whether Relayfile/provider integrations ship in the self-host product;
- per-deployment billing;
- a managed tunnel for customers without inbound HTTPS;
- which hosted desktop/mobile/fleet route groups move into the engine for
  parity;
- final control-plane packaging and UI boundaries.
