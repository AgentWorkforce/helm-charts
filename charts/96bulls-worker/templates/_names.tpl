{{- define "96bulls-worker.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "96bulls-worker.fullname" -}}
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

{{/*
Component object name. Usage: include "96bulls-worker.componentName" (dict "context" . "component" "referee")
*/}}
{{- define "96bulls-worker.componentName" -}}
{{- printf "%s-%s" (include "96bulls-worker.fullname" .context | trunc 40 | trimSuffix "-") .component | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "96bulls-worker.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "96bulls-worker.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Content-addressed Job name: <fullname>-<job>-<sha8>. The hash covers the
image reference and the Job's own values, so changing either yields a new Job
(Job pod templates are immutable; server-side apply cannot patch them).
Usage: include "96bulls-worker.jobName" (dict "context" . "job" "migrate" "config" .Values.migrations)
*/}}
{{- define "96bulls-worker.jobName" -}}
{{- $hash := printf "%s|%s" (include "96bulls-worker.image" .context) (toJson .config) | sha256sum | trunc 8 }}
{{- printf "%s-%s-%s" (include "96bulls-worker.fullname" .context | trunc 40 | trimSuffix "-") .job $hash }}
{{- end }}
