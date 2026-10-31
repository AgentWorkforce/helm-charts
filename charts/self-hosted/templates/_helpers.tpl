{{- define "selfhosted.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "selfhosted.labels" -}}
app.kubernetes.io/name: {{ include "selfhosted.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "selfhosted.validate" -}}
{{- if ne (.Values.profile | default "") "portable-single" }}
{{- fail "profile must be portable-single: aws-ha is not implemented; see docs/aws-ha-gates.md" }}
{{- end }}
{{- if or .Values.addons.awsHa .Values.awsHa }}
{{- fail "aws-ha is not implemented; see docs/aws-ha-gates.md" }}
{{- end }}
{{- if or .Values.addons.relayfile .Values.relayfile }}
{{- fail "Relayfile is not part of the self-hosted chart and is off the AWS hot path" }}
{{- end }}
{{- if not (kindIs "bool" .Values.addons.relaycast) }}
{{- fail "addons.relaycast must be true or false" }}
{{- end }}
{{- $pin := "sha256:a05732ad4f3614d057bb1460df40a30e3a9297c8930bfdda6d4e3d6dc9f41762" }}
{{- if ne (.Values.relaycast.image.digest | default "") $pin }}
{{- fail (printf "relaycast image.digest must stay pinned to %s until a reviewed v12.3.0 publish replaces it" $pin) }}
{{- end }}
{{- if ne (.Values.relaycast.image.repository | default "") "ghcr.io/agentworkforce/relaycast-self-host" }}
{{- fail "relaycast image.repository must stay ghcr.io/agentworkforce/relaycast-self-host" }}
{{- end }}
{{- if ne (.Values.relaycast.runtime.backend | default "sqlite") "sqlite" }}
{{- fail "runtime.backend must be sqlite: no HA Relaycast backend has been released and proven yet" }}
{{- end }}
{{- if ne (int (.Values.relaycast.replicaCount | default 1)) 1 }}
{{- fail "replicaCount must be 1: Relaycast self-host stores SQLite and uploaded files on one persistent volume" }}
{{- end }}
{{- end }}
