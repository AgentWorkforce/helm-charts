{{/*
Expand the name of the chart.
*/}}
{{- define "relaycast-cloud.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "relaycast-cloud.fullname" -}}
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
Create chart name and version as used by the chart label.
*/}}
{{- define "relaycast-cloud.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Name of the service account to use.
*/}}
{{- define "relaycast-cloud.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "relaycast-cloud.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Name of the Secret holding engine credentials. The chart never renders this
Secret: it is either customer-managed or written by External Secrets Operator.
*/}}
{{- define "relaycast-cloud.secretName" -}}
{{- if .Values.secrets.existingSecret -}}
{{- .Values.secrets.existingSecret -}}
{{- else if .Values.externalSecrets.enabled -}}
{{- printf "%s-secrets" (include "relaycast-cloud.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end }}

{{/*
Name of the PVC backing /data.
*/}}
{{- define "relaycast-cloud.claimName" -}}
{{- if .Values.persistence.existingClaim -}}
{{- .Values.persistence.existingClaim -}}
{{- else -}}
{{- printf "%s-data" (include "relaycast-cloud.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end }}

{{/*
Render-time validation. Fails loudly instead of rendering a deployment that
silently does something other than what the values ask for.
*/}}
{{- define "relaycast-cloud.validate" -}}
{{- if not .Values.relaycast.baseUrl -}}
{{- fail "relaycast.baseUrl is required: the public https origin clients use (e.g. https://relay.example.com). The engine refuses http and localhost origins." -}}
{{- end -}}
{{- if not (hasPrefix "https://" .Values.relaycast.baseUrl) -}}
{{- fail "relaycast.baseUrl must start with https:// (the engine refuses plaintext origins)." -}}
{{- end -}}
{{- if ne .Values.database.mode "sqlite" -}}
{{- fail (printf "database.mode=%q is not supported by engine %s: the engine is SQLite-only until its Postgres adapter ships. Use database.mode=sqlite." .Values.database.mode .Chart.AppVersion) -}}
{{- end -}}
{{- if ne .Values.objectStorage.mode "local" -}}
{{- fail (printf "objectStorage.mode=%q is not supported by engine %s: file blobs are stored on the data volume until the engine's S3 adapter ships. Use objectStorage.mode=local." .Values.objectStorage.mode .Chart.AppVersion) -}}
{{- end -}}
{{- if and (eq .Values.database.mode "sqlite") (ne (int .Values.replicaCount) 1) -}}
{{- fail "replicaCount must be 1 with database.mode=sqlite (single-writer SQLite file on a ReadWriteOnce volume; presence, rate limits and realtime are in-process)." -}}
{{- end -}}
{{- if and (not .Values.persistence.existingClaim) (not .Values.persistence.create) -}}
{{- fail "Set persistence.existingClaim to a PVC you manage (recommended), or persistence.create=true to let the chart create one." -}}
{{- end -}}
{{- if and .Values.persistence.existingClaim .Values.persistence.create -}}
{{- fail "Set only one of persistence.existingClaim and persistence.create." -}}
{{- end -}}
{{- if and .Values.relaycast.workspaces.bootstrapProofRequired (not (include "relaycast-cloud.secretName" .)) -}}
{{- fail "relaycast.workspaces.bootstrapProofRequired=true needs the bootstrap secret: set secrets.existingSecret, or enable externalSecrets." -}}
{{- end -}}
{{- if and .Values.externalSecrets.enabled (not .Values.externalSecrets.secretStoreRef.name) -}}
{{- fail "externalSecrets.enabled=true requires externalSecrets.secretStoreRef.name." -}}
{{- end -}}
{{- if and .Values.externalSecrets.enabled (not .Values.externalSecrets.data.workspaceBootstrapSecret.key) -}}
{{- fail "externalSecrets.enabled=true requires externalSecrets.data.workspaceBootstrapSecret.key (a remote reference, never a secret value)." -}}
{{- end -}}
{{- if or (index .Values "cloudnative-pg" "enabled") .Values.postgres.enabled .Values.minio.enabled -}}
{{- fail "cloudnative-pg, postgres and minio subcharts are reserved for the Postgres/S3 path, which engine 12.1.0 does not support yet. Leave them disabled." -}}
{{- end -}}
{{- end }}
