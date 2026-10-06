# Relayflows Helm Chart

This chart runs an Agent Relay Cloud worker in a customer's Kubernetes cluster.
Cloud supplies workflow assignments and short-lived run credentials; the worker
materializes each assignment locally and hands execution to Relayflows. The pod
only initiates outbound HTTPS connections, so the chart creates no Service or
Ingress and needs no cluster-wide RBAC.

## Architecture

- One worker identity per Helm release and exactly one pod per identity.
- A `Recreate` Deployment prevents two pods from consuming the same identity
  during an upgrade.
- A PVC stores `cloud-workers.json`, including the credential returned during
  registration. This state must survive pod replacement because enrollment
  tokens are single-use and expire after 15 minutes.
- The stock configuration installs pinned `agent-relay` and `relayflows` npm
  packages into an `emptyDir` before startup. This is a portable bootstrap path,
  not the recommended production image strategy.
- Production agent flows should use an immutable custom image containing
  `agent-relay`, `flows`, and every harness CLI declared by those flows (for
  example Codex or Claude), with `runtimeInstaller.enabled=false`.

The durable Relayflows kernel uses a local Unix socket. It is intentionally not
exposed as a Kubernetes Service. The Cloud worker is the supported network
boundary: it polls for assignments, starts Relayflows locally, and reports the
result back to Cloud.

This chart packages Cloud's existing long-lived worker contract. Workflow runs
are isolated into per-run directories inside that pod, but the chart does not
create a Kubernetes Job or pod per workflow step. The draft Cloud BYOI
container-per-step/Kubernetes driver is a separate future runtime seam; this
worker does not need Kubernetes API access and does not claim that isolation
model.

## Prerequisites

- Kubernetes 1.21+
- Helm 3.8+
- An x86-64 node when using the stock published Relayflows runtime
- A default StorageClass, or an existing ReadWriteOnce PVC
- Outbound HTTPS access to Agent Relay Cloud, Relayfile, model/provider APIs,
  and (when the stock installer is enabled) the npm registry
- A fresh worker enrollment token from the Cloud workspace's **Runtimes →
  Workers → Add worker** page

## Install

Keep the one-time enrollment token out of shell history and Helm release data:

```bash
kubectl create namespace relayflows
kubectl -n relayflows create secret generic relayflows-enrollment \
  --from-literal=AGENT_RELAY_WORKER_ENROLLMENT_TOKEN='<enrollment-token>'

helm install customer-flows agentworkforce/relayflows \
  --namespace relayflows \
  --set credentials.existingSecret=relayflows-enrollment \
  --set worker.name=customer-k8s
```

The token is redeemed only when the PVC has no registration. On subsequent
pod starts, the persisted worker credential is reused. After the first
successful registration, the one-time enrollment Secret can be deleted; the
Secret reference is optional so replacement pods can start from PVC state.

Check the worker:

```bash
kubectl -n relayflows get pods
kubectl -n relayflows logs deployment/customer-flows-relayflows -c worker -f
```

Select that online worker as the workspace's runtime in Agent Relay Cloud.

## Production image

The default Node image plus init-container installer makes the chart usable
without a separate image release. It does not contain model harness CLIs. Build
an image for the flow types you intend to run:

```dockerfile
FROM node:22-bookworm-slim
ARG AGENT_RELAY_VERSION=12.4.1
ARG RELAYFLOWS_VERSION=2.0.42
RUN npm install -g --ignore-scripts --no-audit --no-fund \
      "agent-relay@${AGENT_RELAY_VERSION}" "relayflows@${RELAYFLOWS_VERSION}"
# Install and pin the required harness CLIs here.
USER node
```

Push it to the customer's registry and install with:

```yaml
image:
  repository: registry.example.com/agentworkforce/relayflows-worker
  tag: "sha-0123456789abcdef"
runtimeInstaller:
  enabled: false
imagePullSecrets:
  - name: registry-credentials
```

The image must provide `/bin/sh`, `agent-relay`, `flows`, and any declared
harness executables. It must run as UID 1000 with a read-only root filesystem;
the chart mounts writable state (and the worker's `HOME`) under
`/var/lib/agent-relay` and writable scratch space at `/tmp`.

## Persistence and lifecycle

The chart-created PVC follows normal Helm ownership and is deleted on
`helm uninstall`. A new install then requires a new enrollment token. To retain
state independently of the release, provision a PVC separately and set:

```yaml
persistence:
  existingClaim: relayflows-worker-state
```

Do not scale a release above one replica. To add capacity, mint another worker
identity and install a second Helm release with its own Secret and PVC.

## Network policy

`networkPolicy.enabled=true` denies arbitrary egress while allowing DNS and TCP
443 to any destination. Use `networkPolicy.egress` to replace those defaults
with the destination selectors or CIDRs supported by your cluster. Ensure the
custom rules cover Cloud, Relayfile, model APIs, source-control providers, and
package registries used by the selected image.

## Parameters

| Parameter | Description | Default |
| --- | --- | --- |
| `image.repository` | Worker/bootstrap image repository | `node` |
| `image.tag` | Worker/bootstrap image tag | `22-bookworm-slim` |
| `image.pullPolicy` | Image pull policy | `IfNotPresent` |
| `imagePullSecrets` | Private registry pull secrets | `[]` |
| `worker.name` | Stable Cloud worker name; release fullname when empty | `""` |
| `worker.cloudUrl` | Agent Relay Cloud or self-hosted Cloud base URL | `https://agentrelay.com/cloud` |
| `worker.terminationGracePeriodSeconds` | Graceful worker drain window | `60` |
| `worker.command` / `worker.args` | Custom image command override | `[]` / `[]` |
| `runtimeInstaller.enabled` | Install pinned CLIs in an init container | `true` |
| `runtimeInstaller.agentRelayVersion` | `agent-relay` package version | `12.4.1` |
| `runtimeInstaller.relayflowsVersion` | `relayflows` package version | `2.0.42` |
| `telemetry.enabled` | Enable optional Agent Relay CLI product telemetry | `false` |
| `credentials.existingSecret` | Secret containing the enrollment token | `""` |
| `credentials.existingSecretKey` | Enrollment-token key in that Secret | `AGENT_RELAY_WORKER_ENROLLMENT_TOKEN` |
| `credentials.enrollmentToken` | Chart-managed enrollment token (development only) | `""` |
| `persistence.existingClaim` | Existing PVC for worker registration state | `""` |
| `persistence.storageClass` | StorageClass; `-` disables dynamic provisioning | `""` |
| `persistence.accessModes` | PVC access modes | `[ReadWriteOnce]` |
| `persistence.size` | PVC request | `5Gi` |
| `serviceAccount.create` | Create a dedicated ServiceAccount | `true` |
| `serviceAccount.automountServiceAccountToken` | Mount Kubernetes API credential | `false` |
| `resources` | Worker requests/limits | requests `250m`, `512Mi` |
| `podDisruptionBudget.enabled` | Create a PDB | `false` |
| `verticalPodAutoscaler.enabled` | Create a VPA | `false` |
| `networkPolicy.enabled` | Restrict pod egress | `false` |
| `networkPolicy.egress` | Complete custom egress rule list | `[]` |
| `nodeSelector` | Pod node selector | `kubernetes.io/arch: amd64` |
| `extraEnv` / `extraEnvFrom` | Extra runtime environment | `[]` / `[]` |
| `extraVolumes` / `extraVolumeMounts` | Customer credential/config mounts | `[]` / `[]` |
| `extraInitContainers` | Additional image/bootstrap initialization | `[]` |

## Uninstall

```bash
helm uninstall customer-flows --namespace relayflows
```

This deletes the chart-managed PVC and registration state. The Cloud worker
record can then be revoked from the workspace UI. Existing PVCs supplied via
`persistence.existingClaim` are not deleted by Helm.
