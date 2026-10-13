# Relayflows Helm Chart

This chart runs Relayflows v2 directly in Kubernetes. Its default `standalone`
mode creates a one-shot Job (or, with `standalone.cron`, a CronJob that starts
one per firing), starts the local `relayflowd` orchestrator inside that pod,
executes the flow, and stores durable run journals on a PVC. It does not enroll
with, call, or otherwise depend on Agent Relay Cloud.

An optional `cloudWorker` mode keeps the existing long-lived worker integration
for teams that want Cloud to assign runs. Neither mode creates a Service,
Ingress, or cluster-wide RBAC.

## Execution model

In standalone mode:

1. Kubernetes starts a revisioned Job, or a CronJob starts a Job on each
   firing when `standalone.cron.enabled=true`.
2. The Job invokes `flows run --no-observer-link` (or `flows resume`).
3. The `flows` CLI starts and connects to `relayflowd` in the same pod.
4. `relayflowd` is the durable orchestrator; its journals live on the PVC.
5. With `standalone.localAgent=true`, agent steps run through harness CLIs in
   the same container.

Cloud is therefore not part of execution. The tradeoff is that Cloud-provided
assignment, hosted event routing, UI observability, and centralized scheduling
are also absent. Set `standalone.cron` for a fixed schedule, or let Kubernetes,
Argo, KEDA, or another local controller create or upgrade releases to trigger
Jobs. The current runtime runs the whole flow in
one pod; it does not create a pod per step.

The chart intentionally creates no webhook listener. A cloud-free POC can run
the Job manually, run it on a schedule with `standalone.cron`, invoke a flow
tick from an existing in-cluster orchestrator, or have the customer's
scheduler/GitOps controller launch it. Hosted
issue-to-pickup routing and Nango are not silently pulled into this path.

The default command always passes `--no-observer-link` and forces
`FLOWS_CLOUD_MIRROR=0`; ambient Secret values cannot opt a standalone run into
hosted publication. It also disables Agent Relay telemetry. A custom
`standalone.command` replaces this contract, so regulated installations should
audit custom commands and enforce their own egress policy.

## Prerequisites

- Kubernetes 1.29+, or 1.22+ with `ReadWriteOncePod` enabled, plus a supporting
  CSI driver
- Helm 3.8+
- An x86-64 node when using the published Relayflows runtime
- A default CSI StorageClass, or an existing `ReadWriteOncePod` PVC
- For agent steps, an image containing the selected harness CLI and a Secret
  containing that provider's credentials
- Outbound access to provider APIs and, when `runtimeInstaller.enabled=true`,
  the npm registry

## Run a local flow

Production flows should be packaged with their source, dependencies, and
harness CLIs in an immutable image:

```dockerfile
FROM node:22.23.3-bookworm-slim
ARG RELAYFLOWS_VERSION=2.0.49
ARG CLAUDE_CODE_VERSION
RUN test -n "${CLAUDE_CODE_VERSION}" && \
    npm install -g --ignore-scripts --no-audit --no-fund \
      "relayflows@${RELAYFLOWS_VERSION}" \
      "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}"
COPY flows/ /app/flows/
USER node
```

Create the model credential without putting it in Helm release data:

```bash
kubectl create namespace relayflows --dry-run=client -o yaml | kubectl apply -f -
umask 077
credential_file=$(mktemp)
trap 'rm -f "$credential_file"' EXIT
printf '%s' "$ANTHROPIC_API_KEY" >"$credential_file"
kubectl -n relayflows create secret generic model-credentials \
  --from-file=ANTHROPIC_API_KEY="$credential_file"
rm -f "$credential_file"
trap - EXIT
```

Use a values file so JSON input and Secret references are not mangled by shell
or Helm `--set` parsing:

```yaml
# local-values.yaml
image:
  repository: registry.example.com/acme/customer-flow
  tag: sha-0123456789abcdef
runtimeInstaller:
  enabled: false
standalone:
  flow:
    path: /app/flows/customer.flow.ts
  input: '{"prompt":"process the queue"}'
extraEnvFrom:
  - secretRef:
      name: model-credentials
```

```bash
helm install customer-flow agentworkforce/relayflows \
  --namespace relayflows \
  --values local-values.yaml
kubectl -n relayflows logs job/customer-flow-relayflows-1 -c runner -f
```

`ANTHROPIC_API_KEY` is inherited by the in-pod Claude Code process. The key is
not sent to Agent Relay Cloud; in standalone mode there is no Cloud process or
Cloud credential at all. The image must still contain the `claude` executable,
and the flow must select the matching harness.

### Keeper or External Secrets Operator

The chart never fetches provider credentials. Point `extraEnvFrom` at the
ordinary Kubernetes Secret materialized by Keeper, External Secrets Operator
(ESO), or the customer's existing secrets pipeline:

```yaml
# The ExternalSecret and SecretStore stay in the platform/ESO release.
# Relayflows only consumes the resulting Kubernetes Secret.
extraEnvFrom:
  - secretRef:
      name: relayflows-provider-credentials
```

That Secret can contain `ANTHROPIC_API_KEY`, other model-provider keys, and
Relayfile mount credentials. Secret values remain pod environment variables;
they are not placed in this Helm release or baked into the image.

For the GitLab POC, the same pattern can provide a narrowly scoped
`GITLAB_TOKEN`. Include `glab` and the required harness CLI in the immutable
image, and either bake in the intended checkout or populate a shared workspace
with `extraInitContainers`. No Nango or Relayfile integration is required for
that preloaded-checkout path.

### ConfigMap flow

A self-contained declarative YAML/JSON flow can be stored in a chart-managed
ConfigMap while the init container installs the published runtime:

```yaml
standalone:
  flow:
    configMapKey: flow.yaml
    content: |-
      # complete Relayflows flow specification
      version: "0.1.0"
      # ...
```

Or mount an existing ConfigMap:

```yaml
standalone:
  flow:
    existingConfigMap: customer-flow
    configMapKey: flow.yaml
```

Use an image-bundled flow when authored TypeScript imports project packages or
when agent steps need harness CLIs. Exactly one of `path`, `content`, or
`existingConfigMap` is required for a new run.

## Durable state and resume

The Job writes run journals and its local home under
`standalone.dataDir` (`/var/lib/relayflows` by default), backed by the release
PVC. The Job has `backoffLimit: 0` because an automatic Kubernetes retry could
start a second flow run. Resume an interrupted, parked, or suspended run
explicitly. The CLI prints the ID as `RUN <run-id> ...`; the same ID is the
filename in `<data-dir>/runs/<run-id>.sqlite3` on the PVC. Record it before
using `ttlSecondsAfterFinished`, because TTL cleanup also removes the pod logs:

```bash
helm upgrade customer-flow agentworkforce/relayflows \
  --namespace relayflows \
  --reset-then-reuse-values \
  --set standalone.resumeRunId=<run-id>
```

Every standalone install or upgrade creates a Job for that Helm revision. Clear
`standalone.resumeRunId` before intentionally starting a fresh run. To retain
journals independently of the release lifecycle, provision a PVC separately.
It must use `ReadWriteOncePod`: unlike `ReadWriteOnce`, that access mode prevents
an old and new Job on the same node from writing the journal simultaneously.

```yaml
persistence:
  existingClaim: relayflows-state
```

## Scheduled runs

Set `standalone.cron.enabled=true` to render a CronJob **instead of** the
per-revision Job. Each firing starts a fresh run (`flows run`) in its own Job,
using the same pod template, `backoffLimit: 0` and `restartPolicy: Never` as
the one-shot Job. `helm upgrade` changes the schedule or pod for later firings
and does not start a run itself.

```yaml
standalone:
  flow:
    path: /app/flows/tick.flow.ts
  cron:
    enabled: true
    schedule: "*/15 * * * *"
    timeZone: America/Los_Angeles
```

Runs share the release PVC, so durable state such as journals or a working
checkout carries from one firing to the next. Runs do not overlap:

- `concurrencyPolicy: Forbid` (the default) skips a firing while the previous
  run is still active. `Replace` stops the active run and starts a new one; the
  interrupted run's journal stays on the PVC. `Allow` is rejected because
  overlapping runs would contend for the `ReadWriteOncePod` journal PVC.
- A run started by hand with
  `kubectl create job --from=cronjob/<name> <job-name>` is not covered by the
  concurrency policy. If a scheduled run is active, the `ReadWriteOncePod`
  claim keeps the manual pod `Pending` until that run finishes.

`standalone.resumeRunId` is rejected in cron mode, because every firing would
resume the same run. To resume an interrupted run, disable cron mode and
resume with a one-off Job, then switch back:

```bash
helm upgrade customer-flow agentworkforce/relayflows --namespace relayflows \
  --reset-then-reuse-values \
  --set standalone.cron.enabled=false \
  --set standalone.resumeRunId=<run-id>
```

`standalone.backoffLimit` must stay `0` in cron mode, since a Kubernetes retry
would start a second run within one firing.

`standalone.cron.suspend=true` is the kill switch: it stops new firings without
deleting the CronJob, its history, or the PVC. Active runs continue; delete
their Job to stop one. `successfulJobsHistoryLimit` and
`failedJobsHistoryLimit` control how many finished Jobs, and so how many pod
logs, are kept. Leave `standalone.ttlSecondsAfterFinished` unset unless logs are
shipped elsewhere, because the TTL removes Jobs regardless of those limits.

`timeZone` requires Kubernetes 1.27+. CronJob names are capped at 52 characters
(Kubernetes appends a suffix to each Job), so the chart truncates the release
fullname to 52 for the CronJob.

## Optional Cloud worker mode

Set `mode: cloudWorker` to run the single-replica, outbound-only Agent Relay
Cloud worker from the original chart design. This mode requires a fresh worker
enrollment token and stores its long-lived registration on the PVC:

```bash
umask 077
token_file=$(mktemp)
trap 'rm -f "$token_file"' EXIT
if ! read -rsp 'Enrollment token: ' enrollment_token; then
  printf '\nUnable to read enrollment token.\n' >&2
  exit 1
fi
printf '\n'
printf '%s' "$enrollment_token" >"$token_file"
unset enrollment_token
kubectl -n relayflows create secret generic relayflows-enrollment \
  --from-file=AGENT_RELAY_WORKER_ENROLLMENT_TOKEN="$token_file"
rm -f "$token_file"
trap - EXIT
helm install customer-worker agentworkforce/relayflows \
  --namespace relayflows \
  --set mode=cloudWorker \
  --set credentials.existingSecret=relayflows-enrollment
```

Cloud mode uses a `Recreate` Deployment so two pods cannot consume one worker
identity. Keep `worker.name`, `worker.cloudUrl`, and the PVC stable after
enrollment. The one-time Secret may be removed after successful registration.
When reinstalling against an already-enrolled `persistence.existingClaim`, the
enrollment Secret may be omitted; a fresh PVC without a token fails at runtime
with a clear message. PDB, VPA, and worker probes apply only to this mode.

## Optional self-hosted Relayfile mount

Relayfile remains an independently installable chart, so it can be upgraded and
scaled separately while staying inside the customer cluster. An ESO-produced
Secret can satisfy its `secrets.existingSecret` value:

```bash
helm install customer-relayfile agentworkforce/relayfile \
  --namespace relayflows \
  --set secrets.existingSecret=relayfile-server-credentials
```

For flows that use Relayfile helpers, include `relayfile-mount` in the immutable
runtime image and add it as a restartable init sidecar in poll mode. Kubernetes
starts it before the runner, shares the mirror directory, and terminates it when
the Job finishes. This needs no FUSE device or privileged container:

```yaml
extraVolumes:
  - name: relayfile-workspace
    emptyDir: {}
extraVolumeMounts:
  - name: relayfile-workspace
    mountPath: /workspace
extraEnv:
  - name: RELAYFILE_MOUNT_PATH
    value: /workspace
extraInitContainers:
  - name: relayfile-mount
    restartPolicy: Always
    image: registry.example.com/acme/customer-flow:sha-0123456789abcdef
    command: [relayfile-mount]
    env:
      - name: RELAYFILE_BASE_URL
        value: http://customer-relayfile:8080
      - name: RELAYFILE_WORKSPACE
        value: ws_customer
      - name: RELAYFILE_LOCAL_DIR
        value: /workspace
      - name: RELAYFILE_MOUNT_MODE
        value: poll
      - name: RELAYFILE_TOKEN
        valueFrom:
          secretKeyRef:
            name: relayflows-provider-credentials
            key: RELAYFILE_TOKEN
    volumeMounts:
      - name: relayfile-workspace
        mountPath: /workspace
```

This keeps the server, workspace mirror, credentials, flow source, journals,
run logs, and attribution records in-cluster. Model calls use the customer's
BYO provider keys directly; no AgentWorkforce metering component is involved.
For a hard network boundary, enable `networkPolicy` and replace its default
broad HTTPS rule with only the in-cluster Relayfile service and approved model
provider destinations. Standard Kubernetes NetworkPolicy matches CIDRs and pod
selectors, not DNS names; use the cluster CNI's FQDN policy when endpoint-level
allowlisting is required.

## Local observability and flow permissions

Standalone runs write the durable journal and attribution records to the PVC
and write ordinary process output to Kubernetes pod logs. Existing cluster
agents can collect those logs for Datadog, and customer tooling can inspect the
SQLite journals locally. The chart exposes no hosted observer or metrics
dependency; Prometheus/Grafana integration can be added through the customer's
standard collectors.

Permission and skill scopes belong to the flow specification, not to Cloud or
the Helm release. A POC can therefore use the broader scope Julian requested,
while production flow images and values can narrow filesystem, tool, Secret,
and network access without changing execution mode.

## Regulated deployment tiers and retention

The Kubernetes pod is the sandbox boundary for this chart; steps do not receive
separate pods. Teams can express dev-to-production restriction tiers as reviewed
values files and namespace policy:

- development may allow the runtime installer, broad HTTPS egress, and broader
  flow permissions;
- production should use a digest-pinned immutable image, disable the runtime
  installer, enable destination-restricted egress, set resource limits, and
  apply the cluster's admission, workload-identity, and namespace policies;
- both tiers retain the default non-root user, read-only root filesystem,
  dropped capabilities, `RuntimeDefault` seccomp profile, and disabled
  Kubernetes API token.

The chart does not claim to provide SOC-2 controls by itself. For required
retention and encryption, use `persistence.existingClaim` with the customer's
encrypted StorageClass, snapshot/backup policy, and retention lifecycle. Route
pod logs only to the customer's in-cluster or approved logging stack. The
chart-created PVC is deleted on `helm uninstall`, so it is inappropriate when
run journals and attribution records must survive release deletion.

## Network policy and security

`networkPolicy.enabled=true` denies ingress and permits DNS plus outbound TCP
443. Set `networkPolicy.egress` to replace broad HTTPS egress with cluster-
specific selectors or CIDRs. Standalone agent flows usually need model API,
source-control, and package-registry destinations; Cloud mode additionally
needs the configured Cloud and Relayfile endpoints.

Pods run as UID 1000, drop Linux capabilities, use a read-only root filesystem,
and do not mount a Kubernetes API token by default. Writable PVC and `/tmp`
mounts are provided. `extraEnv`, `extraEnvFrom`, `extraVolumes`, and
`extraVolumeMounts` pass customer credentials and configuration to the runtime.

## Upgrading

### From 0.2.0 or 0.2.1 (relayflows 2.0.42) to 0.2.2 (relayflows 2.0.49)

**Do not upgrade with plain `--reuse-values`.** Helm's `--reuse-values` keeps
the previous chart's defaults as well as your own values, so 0.2.0 and 0.2.1's
default `runtimeInstaller.relayflowsVersion: "2.0.42"` is carried forward and
new pods keep installing 2.0.42. Use `--reset-then-reuse-values` (Helm 3.14+),
which keeps your values but takes this chart's defaults:

```bash
helm upgrade customer-flow agentworkforce/relayflows --namespace relayflows \
  --reset-then-reuse-values
```

On Helm older than 3.14, keep `--reuse-values` and add
`--set runtimeInstaller.relayflowsVersion=2.0.49`. If an upgrade still installs
an older runtime than the chart's `appVersion`, the release notes print a
warning. From 0.2.2 on, `runtimeInstaller.relayflowsVersion` defaults to empty,
which means the chart's `appVersion`, so later chart upgrades move the runtime
even with `--reuse-values` unless you pinned it.


Apart from how the runtime version is resolved, the rendered Job/CronJob, the
`flows run`/`flows resume` command and its flags, and the forced
`FLOWS_CLOUD_MIRROR=0` / `AGENT_RELAY_TELEMETRY_DISABLED=1` are identical. Only
the default runtime moves. With an immutable image, the runtime is whatever
the image installs, so rebuild it with `RELAYFLOWS_VERSION=2.0.49`; bumping the
chart alone changes nothing for you.

Journals on the PVC need no migration. The journal storage format did not
change between these versions, and an interrupted 2.0.42 run can be resumed
by 2.0.49 with `standalone.resumeRunId`. Runtime behavior changes you should
know about:

- **Deterministic commands default to a 10 minute timeout, not 30 seconds.**
  This covers `f.run` and declarative `type: deterministic` steps with no
  explicit timeout. Commands that took longer than 30s, and used to fail with
  `timeout`, now succeed. A hung command (for example `glab` waiting on the
  network) now holds the pod for up to 10 minutes. The `f.run` maximum is still
  15 minutes. Pass an explicit `timeout` to keep a tighter bound, and size
  `standalone.activeDeadlineSeconds` and the cron interval for the longer
  default.
- **An agent step that hits its `timeout` is continued once by default.**
  The second attempt runs in the same dirty workspace and sees the first
  attempt's edits. A second deadline ends the step. Worst-case wall time and
  model spend for a timed-out agent step are about twice its `timeout`. Set
  `transportRetries: 0` on the step to keep the old behavior, where the
  deadline is the result. With `concurrencyPolicy: Forbid`, a longer run skips
  more cron firings.
- **Claude Code receives the task after `--`.** The worker now runs
  `claude -p --dangerously-skip-permissions ... -- <task>`. Before, the task
  was a bare final word, so a task beginning with `-` was parsed as an option.
  Check that the Claude Code version pinned in your image accepts `--`.
- **`f.run` gets the environment of the `flows` process that started the
  run.** It no longer gets the environment of whichever process started
  `relayflowd`. Each pod has one CLI, so in this chart deterministic steps
  still see the pod environment (`extraEnv`/`extraEnvFrom`), as before.
  `f.run` calls within one run still execute one at a time.
- **A slow daemon no longer kills the run.** Under CPU throttling, a read that
  exceeds its budget now exits 1 with `daemon_unresponsive`, and the run stays
  resumable. Resume it with `standalone.resumeRunId`.
- **`--detach` is new and must not be used here.** It returns before the run
  finishes, so the pod would exit and stop `relayflowd`. The chart never
  passes it. If you use a custom `standalone.command`, do not add it there
  either.

The Node.js requirement is unchanged (`>=20`), and the default image is
still `node:22.23.3-bookworm-slim`.

## Parameters

| Parameter | Description | Default |
| --- | --- | --- |
| `mode` | `standalone` Job/CronJob or `cloudWorker` Deployment | `standalone` |
| `image.repository` / `image.tag` | Runtime image | `node` / `22.23.3-bookworm-slim` |
| `image.pullPolicy` / `imagePullSecrets` | Image pull configuration | `IfNotPresent` / `[]` |
| `standalone.flow.path` | Flow path bundled in the image | `""` |
| `standalone.flow.content` | Flow stored in a generated ConfigMap | `""` |
| `standalone.flow.existingConfigMap` | Existing flow ConfigMap | `""` |
| `standalone.flow.configMapKey` | Flow key and mounted filename | `flow.yaml` |
| `standalone.input` | JSON input for a new run; requires an authored `*.flow.ts`/`.mts`/`.js`/`.mjs` flow | `""` |
| `standalone.resumeRunId` | Durable run ID to resume instead of starting | `""` |
| `standalone.localAgent` / `agentCapacity` | Run local agent workers and capacity | `true` / `1` |
| `standalone.dataDir` | PVC-backed relayflowd data directory | `/var/lib/relayflows` |
| `standalone.backoffLimit` | Kubernetes Job retries | `0` |
| `standalone.activeDeadlineSeconds` | Optional Job deadline | `null` |
| `standalone.ttlSecondsAfterFinished` | Optional completed-Job TTL | `null` |
| `standalone.command` / `standalone.args` | Custom runner command | `[]` / `[]` |
| `standalone.cron.enabled` | Render a CronJob instead of the per-revision Job | `false` |
| `standalone.cron.schedule` | Cron schedule for new runs | `*/15 * * * *` |
| `standalone.cron.timeZone` | IANA time zone (Kubernetes 1.27+) | `""` |
| `standalone.cron.suspend` | Stop new firings without deleting the CronJob | `false` |
| `standalone.cron.concurrencyPolicy` | `Forbid` or `Replace`; `Allow` is rejected | `Forbid` |
| `standalone.cron.startingDeadlineSeconds` | Skip a firing missed by more than this many seconds | `300` |
| `standalone.cron.successfulJobsHistoryLimit` / `failedJobsHistoryLimit` | Finished Jobs (and logs) kept | `3` / `5` |
| `worker.*` | Cloud worker identity, URL, grace period, command | see `values.yaml` |
| `runtimeInstaller.enabled` | Install pinned runtime CLIs at pod startup | `true` |
| `runtimeInstaller.relayflowsVersion` | Relayflows package version; empty uses the chart `appVersion` | `""` (2.0.49) |
| `runtimeInstaller.agentRelayVersion` | Cloud-mode agent-relay version | `12.4.1` |
| `credentials.*` | Cloud-mode enrollment Secret or token | unset |
| `persistence.existingClaim` | Existing durable-state PVC | `""` |
| `persistence.storageClass` / `size` | Chart PVC class and request | `""` / `5Gi` |
| `persistence.accessModes` | PVC access; keep pod-exclusive for safe upgrades | `[ReadWriteOncePod]` |
| `serviceAccount.*` | ServiceAccount settings | created; token disabled |
| `podSecurityContext` / `containerSecurityContext` | Pod security settings | non-root hardened defaults |
| `resources` / `runtimeInstaller.resources` | Runner and installer resources | see `values.yaml` |
| `networkPolicy.enabled` / `egress` | Deny ingress and control egress | `false` / `[]` |
| `podDisruptionBudget.*` / `verticalPodAutoscaler.*` | Cloud-mode availability and sizing | disabled |
| `nodeSelector` | Runtime architecture selector | `kubernetes.io/arch: amd64` |
| `tolerations` / `affinity` | Pod scheduling | `[]` / `{}` |
| `extraEnv` / `extraEnvFrom` | Provider and runtime environment | `[]` / `[]` |
| `extraVolumes` / `extraVolumeMounts` | Customer mounts | `[]` / `[]` |
| `extraInitContainers` | Additional initialization | `[]` |

## Uninstall

```bash
helm uninstall customer-flow --namespace relayflows
```

This deletes a chart-managed PVC and its journals. A PVC supplied through
`persistence.existingClaim` is not owned or deleted by the chart.
