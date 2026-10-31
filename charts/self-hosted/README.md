# Self-hosted composition

This chart is the self-hosted product composition. It installs nothing from
Relaycast until `addons.relaycast` is `true`. The default release is a contract
ConfigMap only.

When Relaycast is enabled, the chart installs `charts/relaycast` **0.2.0**
unchanged: the published image
`ghcr.io/agentworkforce/relaycast-self-host@sha256:a05732ad4f3614d057bb1460df40a30e3a9297c8930bfdda6d4e3d6dc9f41762`
(`12.2.1-selfhost.1`). That is the portable-single baseline. A newer engine
line is tracked in
[helm-charts #23](https://github.com/AgentWorkforce/helm-charts/issues/23)
and is not selected here.

Relayfile is not a dependency. It stays off this chart and off the AWS hot
path. There is no aws-ha profile. The missing proofs are listed in
[docs/aws-ha-gates.md](../../docs/aws-ha-gates.md).

## Support tier

| | |
|---|---|
| Profile | `portable-single` only |
| Replicas | exactly 1 |
| Upgrade strategy | `Recreate` |
| Database | SQLite on the data volume (`/data/relaycast.db`) |
| Volume access | `ReadWriteOnce` (or `ReadWriteOncePod` only when backups are off; the Relaycast chart enforces that) |
| Secrets | existing Secret, mounted read-only as `*_FILE` |
| Exposure | ClusterIP, NetworkPolicy admits the release namespace unless you set `relaycast.networkPolicy.ingressFrom` |
| HA | not supported |

`runtime.backend` other than `sqlite`, `replicaCount` other than 1, a second
image digest, and `profile: aws-ha` are rejected at render time.

## Rollback boundary

Relaycast 0.2.0 migrates the SQLite schema on boot. **`helm rollback` to chart
0.1.0 (image 8.0.0) is not supported after that migration has started.** The
0.1.0 engine fails authenticated calls with `no such column: "plan"` while
`/health` can still return 200. Roll forward with `helm upgrade` and the 0.2.0
values. When backups are enabled, `helm rollback` also cannot re-adopt the
retained backup PVC (`spec is immutable`); an upgrade can.

Releases on the 12.x line apply forward-only migrations. Take a backup before
every upgrade. Restoring a backup from the chart's CronJob is
`ci/relaycast/restore.sh`. An existing 0.1.0 install is private-test only.
This chart does not upgrade or delete one.

## Generic Kubernetes

```bash
kubectl create namespace self-hosted
kubectl -n self-hosted create secret generic relaycast-secrets \
  --from-literal=internal-secret="$(openssl rand -hex 32)" \
  --from-literal=workspace-bootstrap-secret="$(openssl rand -hex 32)"
helm install self-hosted oci://ghcr.io/agentworkforce/charts/self-hosted \
  --version 0.1.0 -n self-hosted \
  -f charts/self-hosted/examples/kubernetes.yaml
```

`examples/kubernetes.yaml` turns the add-on on. Omit that file, or set
`addons.relaycast=false`, to install the composition with no Relaycast
workload. The first workspace is created through the in-cluster admin API, the
same way as [charts/relaycast/README.md](../relaycast/README.md).

## AWS EKS

EKS is a Kubernetes destination for the same profile. Use
`examples/eks.yaml` when the cluster's RWO StorageClass is `gp3`. That name
is not an Aurora, ElastiCache, SQS, or S3 setting. Do not point this chart at
those services. The engine does not implement those adapters yet
([docs/aws-ha-gates.md](../../docs/aws-ha-gates.md)).

## What the kind smoke proves

`ci/self-hosted/smoke.sh` builds a throwaway kind cluster and, from an empty
namespace, checks:

- default-off install renders no Relaycast workload
- enabled install becomes Ready
- anonymous `POST /v1/workspaces` is 404 and unauthenticated `/internal` is not a create
- the documented bootstrap creates a workspace, then the authenticated client smoke reads it back
- secret keys are mounted read-only as files, not plain environment variables
- a pod in another namespace cannot reach the Service while a same-namespace pod can
- a restart keeps the workspace, and a backup restore removes a message written after the backup

It does not install an ingress controller. The ingress paths `/internal` and
`/v1/workspaces` are routed to an endpoint-less Service in
`ci/ingress-values.yaml`, checked by `scripts/ci/charts.sh`. It does not reuse
another cluster's Relaycast namespace.
