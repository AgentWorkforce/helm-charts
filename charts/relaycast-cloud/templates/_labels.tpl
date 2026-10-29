{{/*
Common labels.
*/}}
{{- define "relaycast-cloud.labels" -}}
helm.sh/chart: {{ include "relaycast-cloud.chart" . }}
{{ include "relaycast-cloud.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: relaycast
{{- end }}

{{/*
Selector labels.
*/}}
{{- define "relaycast-cloud.selectorLabels" -}}
app.kubernetes.io/name: {{ include "relaycast-cloud.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Component labels.
Usage: include "relaycast-cloud.componentLabels" (dict "context" . "component" "server")
*/}}
{{- define "relaycast-cloud.componentLabels" -}}
{{ include "relaycast-cloud.labels" .context }}
app.kubernetes.io/component: {{ .component }}
{{- end }}

{{/*
Component selector labels.
*/}}
{{- define "relaycast-cloud.componentSelectorLabels" -}}
{{ include "relaycast-cloud.selectorLabels" .context }}
app.kubernetes.io/component: {{ .component }}
{{- end }}
