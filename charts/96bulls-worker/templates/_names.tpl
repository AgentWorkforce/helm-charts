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
Join name parts and fit them in 63 chars. When too long, keep a prefix and
append a hash of the full name so two long release names never collide.
Usage: include "96bulls-worker.fit" "<name>"
*/}}
{{- define "96bulls-worker.fit" -}}
{{- if le (len .) 63 }}{{ . }}{{ else }}{{ printf "%s-%s" (trunc 54 . | trimSuffix "-") (sha256sum . | trunc 8) }}{{ end -}}
{{- end }}

{{/*
Component object name. Usage: include "96bulls-worker.componentName" (dict "context" . "component" "referee")
*/}}
{{- define "96bulls-worker.componentName" -}}
{{- include "96bulls-worker.fit" (printf "%s-%s" (include "96bulls-worker.fullname" .context) .component) }}
{{- end }}

{{- define "96bulls-worker.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "96bulls-worker.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Content-addressed Job name: <fullname>-<job>-<sha8 of the rendered Job spec>.
Hashing the spec itself means ANY change to the pod template (image, env,
secret names, security context, ...) yields a new Job: Job pod templates are
immutable and server-side apply cannot patch them.
Usage: include "96bulls-worker.jobName" (dict "context" . "job" "migrate" "spec" $spec)
*/}}
{{- define "96bulls-worker.jobName" -}}
{{- $base := include "96bulls-worker.fit" (printf "%s-%s" (include "96bulls-worker.fullname" .context) .job) | trunc 54 | trimSuffix "-" }}
{{- printf "%s-%s" $base (sha256sum .spec | trunc 8) }}
{{- end }}
