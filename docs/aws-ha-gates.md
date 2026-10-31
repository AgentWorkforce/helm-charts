# aws-ha gates

Status: frozen list. No aws-ha chart, values profile, or backend selector
exists. `charts/self-hosted` rejects `profile` other than `portable-single`
and `runtime.backend` other than `sqlite`.

Helm must not grow an HA release until the Relaycast engine owns the adapters
and a provider-neutral conformance suite has evidence. Provider differences
belong behind those adapters, not in chart conditionals that pretend the
adapters are already there.

Relayfile is not part of `charts/self-hosted` and is not on this path.

## The six proofs that are still missing

All six are open. Linking a design doc is not evidence.

1. **Postgres adapter.** Engine-owned. Design only, and the design says nothing
   is implemented: [relaycast #602](https://github.com/AgentWorkforce/relaycast/pull/602)
   at `38061a9af16c5a9e15adc1d5d494babc6c6018c7`. Search is specified on
   Postgres alone, with ClickHouse as an opt-in. There is no Helm backend for
   it.
2. **Redis pub/sub adapter.** No engine implementation, chart, or proof for
   realtime fan-out and ephemeral coordination.
3. **SQS adapter.** No engine implementation, chart, or proof for durable
   asynchronous delivery.
4. **S3 adapter.** Named as future file storage in the #602 design. No
   implementation and no proof of upload, download, expiry, and cleanup.
5. **Provider-neutral conformance suite.** No suite in Relaycast that Helm can
   select to show Postgres, Redis, queue, and object behavior without AWS
   branches. The portable-single kind smoke is not that suite.
6. **EKS aws-ha end-to-end proof.** Not run. Installing portable-single on EKS
   (SQLite, one replica, ReadWriteOnce) is not this proof. The unproven AWS
   list in [self-hosted-reference-architecture.md](self-hosted-reference-architecture.md)
   stays unproven: fresh install and upgrade, workspace and REST and
   WebSocket delivery, multi-replica fan-out, object expiry, queue replay,
   availability-zone failure, backup RPO/RTO, observability, the 96Bulls
   add-on path, add-ons disabled independently, and no AWS-specific engine
   branches.

## What may merge before those proofs

A chart may keep shipping `portable-single`: Relaycast 0.2.0, one replica,
`Recreate`, SQLite, `ReadWriteOnce`, secrets as files, ClusterIP. EKS may
appear only as a cluster where that profile runs, including a StorageClass
name.

## What may not merge

- A values key that selects Postgres, Redis, SQS, S3, Aurora, RDS, or
  ElastiCache.
- `replicaCount` greater than 1.
- A chart named or profiled `aws-ha` whose rendered workloads are still the
  SQLite release.
- A Relayfile dependency on the self-hosted or Relaycast release.

`gcp-ha` stays behind this list. It is not a second shortcut.
