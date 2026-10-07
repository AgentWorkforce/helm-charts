{{/* Expand the chart name. */}}
{{- define "relayflows.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/* Create a DNS-safe fully qualified name. */}}
{{- define "relayflows.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/* Chart label. */}}
{{- define "relayflows.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/* Validate and return the execution mode. */}}
{{- define "relayflows.mode" -}}
{{- if and (ne .Values.mode "standalone") (ne .Values.mode "cloudWorker") -}}
{{- fail "mode must be either standalone or cloudWorker" -}}
{{- end -}}
{{- .Values.mode -}}
{{- end }}

{{/* Common labels. */}}
{{- define "relayflows.labels" -}}
helm.sh/chart: {{ include "relayflows.chart" . }}
{{ include "relayflows.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/* Immutable selector labels. */}}
{{- define "relayflows.selectorLabels" -}}
app.kubernetes.io/name: {{ include "relayflows.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: {{ ternary "runner" "worker" (eq (include "relayflows.mode" .) "standalone") }}
{{- end }}

{{/* Standalone Jobs are revisioned because their pod templates are immutable. */}}
{{- define "relayflows.jobName" -}}
{{- $suffix := printf "-%d" .Release.Revision -}}
{{- $baseLength := sub 63 (len $suffix) | int -}}
{{- $base := include "relayflows.fullname" . | trunc $baseLength | trimSuffix "-" -}}
{{- printf "%s%s" $base $suffix -}}
{{- end }}

{{/*
Whether standalone runs on a schedule. Nil-safe so `helm upgrade --reuse-values`
from a release whose stored values predate standalone.cron keeps rendering.
*/}}
{{- define "relayflows.cronEnabled" -}}
{{- if dig "cron" "enabled" false .Values.standalone -}}true{{- end -}}
{{- end }}

{{/*
Standalone CronJobs keep a stable name across revisions. Kubernetes appends an
11-character suffix to the Jobs it spawns, so CronJob names are capped at 52.
*/}}
{{- define "relayflows.cronJobName" -}}
{{- $fullname := include "relayflows.fullname" . -}}
{{- if gt (len $fullname) 52 -}}
{{- printf "%s-%s" ($fullname | trunc 41 | trimSuffix "-") ($fullname | sha256sum | trunc 10) -}}
{{- else -}}
{{- $fullname -}}
{{- end -}}
{{- end }}

{{/* Chart-managed standalone flow ConfigMap name. */}}
{{- define "relayflows.flowConfigMapName" -}}
{{- printf "%s-flow" (include "relayflows.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end }}

{{/* Validate and return a Kubernetes ConfigMap data key. */}}
{{- define "relayflows.flowConfigMapKey" -}}
{{- $key := required "standalone.flow.configMapKey must not be empty" .Values.standalone.flow.configMapKey -}}
{{- if not (regexMatch "^[A-Za-z0-9._-]+$" $key) -}}
{{- fail "standalone.flow.configMapKey may contain only letters, numbers, '-', '_' or '.'" -}}
{{- end -}}
{{- $key -}}
{{- end }}

{{/* Service account name. */}}
{{- define "relayflows.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "relayflows.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/* Credential Secret name. */}}
{{- define "relayflows.secretName" -}}
{{- if .Values.credentials.existingSecret -}}
{{- .Values.credentials.existingSecret -}}
{{- else -}}
{{- include "relayflows.fullname" . -}}
{{- end -}}
{{- end }}

{{/* PersistentVolumeClaim name. */}}
{{- define "relayflows.pvcName" -}}
{{- default (include "relayflows.fullname" .) .Values.persistence.existingClaim -}}
{{- end }}

{{/* Stable worker name. */}}
{{- define "relayflows.workerName" -}}
{{- default (include "relayflows.fullname" .) .Values.worker.name | trunc 128 -}}
{{- end }}

{{/* Full image reference. */}}
{{- define "relayflows.image" -}}
{{- $tag := required "image.tag is required because Chart.appVersion tracks the Relayflows runtime, not the bootstrap image" .Values.image.tag -}}
{{- printf "%s:%s" .Values.image.repository $tag -}}
{{- end }}

{{/* Resolve and validate the standalone flow source. */}}
{{- define "relayflows.standaloneFlowPath" -}}
{{- $flow := .Values.standalone.flow -}}
{{- $sourceCount := 0 -}}
{{- if $flow.path }}{{- $sourceCount = add1 $sourceCount -}}{{- end -}}
{{- if $flow.content }}{{- $sourceCount = add1 $sourceCount -}}{{- end -}}
{{- if $flow.existingConfigMap }}{{- $sourceCount = add1 $sourceCount -}}{{- end -}}
{{- if ne $sourceCount 1 -}}
{{- fail "standalone requires exactly one of standalone.flow.path, standalone.flow.content, or standalone.flow.existingConfigMap (unless standalone.resumeRunId is set)" -}}
{{- end -}}
{{- if or $flow.content $flow.existingConfigMap -}}
{{- printf "/opt/relayflows/flow/%s" (include "relayflows.flowConfigMapKey" .) -}}
{{- else -}}
{{- $flow.path -}}
{{- end -}}
{{- end }}

{{/* Default standalone invocation. relayflowd is spawned locally by the CLI. */}}
{{- define "relayflows.standaloneScript" -}}
set -eu
mkdir -p "${HOME}" "${RELAYFLOWS_DATA_DIR}"
{{- if .Values.standalone.resumeRunId }}
exec flows resume \
  --no-observer-link \
  --data-dir "${RELAYFLOWS_DATA_DIR}"{{ if .Values.standalone.localAgent }} \
  --local-agent \
  --agent-capacity "${RELAYFLOWS_AGENT_CAPACITY}"{{ end }} \
  "${RELAYFLOWS_RUN_ID}"
{{- else }}
exec flows run \
  --no-observer-link \
  --data-dir "${RELAYFLOWS_DATA_DIR}"{{ if .Values.standalone.localAgent }} \
  --local-agent \
  --agent-capacity "${RELAYFLOWS_AGENT_CAPACITY}"{{ end }}{{ if .Values.standalone.input }} \
  --input "${RELAYFLOWS_INPUT}"{{ end }} \
  "${RELAYFLOWS_FLOW_PATH}"
{{- end }}
{{- end }}

{{/* Default worker bootstrap and foreground process. */}}
{{- define "relayflows.workerScript" -}}
set -eu
mkdir -p "${HOME}"
store="${AGENT_RELAY_HOME}/cloud-workers.json"
if [ -s "${store}" ]; then
  if ! agent-relay cloud worker status \
    --name "${AGENT_RELAY_WORKER_NAME}" \
    --base-url "${AGENT_RELAY_CLOUD_URL}" \
    --json >/dev/null 2>&1; then
    echo "Persisted state does not contain exactly one registration for worker '${AGENT_RELAY_WORKER_NAME}' at '${AGENT_RELAY_CLOUD_URL}'." >&2
    echo "Keep worker.name and worker.cloudUrl stable when reusing a PVC, or enroll with an empty PVC." >&2
    exit 1
  fi
else
  if [ -z "${AGENT_RELAY_WORKER_ENROLLMENT_TOKEN:-}" ]; then
    echo "No persisted worker registration or enrollment token was found." >&2
    exit 1
  fi
  agent-relay cloud worker register \
    --token "${AGENT_RELAY_WORKER_ENROLLMENT_TOKEN}" \
    --name "${AGENT_RELAY_WORKER_NAME}" \
    --base-url "${AGENT_RELAY_CLOUD_URL}"
fi
exec agent-relay cloud worker start \
  --name "${AGENT_RELAY_WORKER_NAME}" \
  --base-url "${AGENT_RELAY_CLOUD_URL}"
{{- end }}
