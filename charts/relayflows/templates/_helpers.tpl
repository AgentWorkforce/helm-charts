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
app.kubernetes.io/component: worker
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
{{- $tag := .Values.image.tag | default .Chart.AppVersion -}}
{{- printf "%s:%s" .Values.image.repository $tag -}}
{{- end }}

{{/* Default worker bootstrap and foreground process. */}}
{{- define "relayflows.workerScript" -}}
set -eu
mkdir -p "${HOME}"
store="${AGENT_RELAY_HOME}/cloud-workers.json"
if [ ! -s "${store}" ]; then
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
