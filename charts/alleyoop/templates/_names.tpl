{{- define "alleyoop.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "alleyoop.fullname" -}}
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
Component object name. Usage: include "alleyoop.componentName" (dict "context" . "component" "referee")
*/}}
{{- define "alleyoop.componentName" -}}
{{- printf "%s-%s" (include "alleyoop.fullname" .context | trunc 40 | trimSuffix "-") .component | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "alleyoop.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "alleyoop.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}
