{{- define "relay-dashboard.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- define "relay-dashboard.fullname" -}}
{{- if .Values.fullnameOverride }}{{ .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}{{ else }}{{ printf "%s-%s" .Release.Name (include "relay-dashboard.name" .) | trunc 63 | trimSuffix "-" }}{{ end }}
{{- end -}}
{{- define "relay-dashboard.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
{{ include "relay-dashboard.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: agent-relay
{{- end -}}
{{- define "relay-dashboard.selectorLabels" -}}
app.kubernetes.io/name: {{ include "relay-dashboard.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}
{{- define "relay-dashboard.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}{{ default (include "relay-dashboard.fullname" .) .Values.serviceAccount.name }}{{ else }}{{ default "default" .Values.serviceAccount.name }}{{ end }}
{{- end -}}
{{- define "relay-dashboard.image" -}}
{{- $digest := required "image.digest is required; relay-dashboard images must be pinned by sha256 digest" .Values.image.digest -}}
{{- if not (regexMatch "^sha256:[a-f0-9]{64}$" $digest) }}{{ fail "image.digest must be sha256:<64 lowercase hex characters>" }}{{ end -}}
{{- printf "%s@%s" .Values.image.repository $digest -}}
{{- end -}}
{{- define "relay-dashboard.validate" -}}
{{- $image := include "relay-dashboard.image" . -}}
{{- if ne (int .Values.replicaCount) 1 }}{{ fail "replicaCount must be 1: the dashboard image serves one static replica and the chart makes no HA claim" }}{{ end -}}
{{- if ne .Values.service.type "ClusterIP" }}{{ fail "service.type must be ClusterIP; expose the dashboard only through ingress" }}{{ end -}}
{{- if not (regexMatch "^https://[^/?#]+$" .Values.runtime.publicUrl) }}{{ fail "runtime.publicUrl must be an HTTPS origin with no path" }}{{ end -}}
{{- range $name, $path := dict "appPath" .Values.runtime.appPath "apiBasePath" .Values.runtime.apiBasePath "loginPath" .Values.runtime.loginPath }}{{ if not (regexMatch "^/[^?#]*$" $path) }}{{ fail (printf "runtime.%s must be an absolute path without query or fragment" $name) }}{{ end }}{{ end -}}
{{- if .Values.ingress.enabled -}}
{{- if not .Values.ingress.host }}{{ fail "ingress.host is required when ingress.enabled=true" }}{{ end -}}
{{- if not (regexMatch "^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$" .Values.ingress.host) }}{{ fail "ingress.host must be a DNS hostname" }}{{ end -}}
{{- if and (not .Values.ingress.externalTls) (empty .Values.ingress.tls) }}{{ fail "ingress.enabled=true requires ingress.tls unless externalTls=true" }}{{ end -}}
{{- if not .Values.api.serviceName }}{{ fail "api.serviceName is required; runtime.apiBasePath must fail closed to relay-cloud-api" }}{{ end -}}
{{- if and .Values.networkPolicy.enabled (empty .Values.networkPolicy.ingressFrom) }}{{ fail "ingress with networkPolicy requires networkPolicy.ingressFrom" }}{{ end -}}
{{- end -}}
{{- end -}}
