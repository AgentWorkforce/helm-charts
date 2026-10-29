{{- define "96bulls-worker.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "96bulls-worker.selectorLabels" -}}
app.kubernetes.io/name: {{ include "96bulls-worker.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "96bulls-worker.labels" -}}
helm.sh/chart: {{ include "96bulls-worker.chart" . }}
{{ include "96bulls-worker.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: 96bulls
{{- end }}

{{/*
Usage: include "96bulls-worker.componentLabels" (dict "context" . "component" "referee")
*/}}
{{- define "96bulls-worker.componentLabels" -}}
{{ include "96bulls-worker.labels" .context }}
app.kubernetes.io/component: {{ .component }}
{{- end }}

{{- define "96bulls-worker.componentSelectorLabels" -}}
{{ include "96bulls-worker.selectorLabels" .context }}
app.kubernetes.io/component: {{ .component }}
{{- end }}
