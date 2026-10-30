{{- define "relaycast.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "relaycast.fullname" -}}
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

{{- define "relaycast.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "relaycast.labels" -}}
helm.sh/chart: {{ include "relaycast.chart" . }}
{{ include "relaycast.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "relaycast.selectorLabels" -}}
app.kubernetes.io/name: {{ include "relaycast.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "relaycast.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "relaycast.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{- define "relaycast.claimName" -}}
{{- default (printf "%s-data" (include "relaycast.fullname" .)) .Values.persistence.existingClaim }}
{{- end }}

{{- define "relaycast.image" -}}
{{- $digest := required "image.digest is required; Relaycast images must be pinned by sha256 digest" .Values.image.digest }}
{{- if not (regexMatch "^sha256:[a-f0-9]{64}$" $digest) }}
{{- fail "image.digest must be sha256:<64 lowercase hex characters>" }}
{{- end }}
{{- printf "%s@%s" .Values.image.repository $digest }}
{{- end }}

{{- define "relaycast.validate" -}}
{{- if ne (int .Values.replicaCount) 1 }}
{{- fail "replicaCount must be 1: Relaycast self-host stores SQLite and uploaded files on one persistent volume" }}
{{- end }}
{{- if ne .Values.runtime.backend "sqlite" }}
{{- fail "runtime.backend must be sqlite: no HA Relaycast backend has been released and proven yet" }}
{{- end }}
{{- if not .Values.baseUrl }}
{{- fail "baseUrl is required and must be the public HTTPS Relaycast origin" }}
{{- end }}
{{- $originPattern := "^https://([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\\.)+[A-Za-z]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(:[0-9]{1,5})?$" }}
{{- if not (regexMatch $originPattern .Values.baseUrl) }}
{{- fail "baseUrl must be an HTTPS origin with public multi-label DNS and no credentials, path, query, or fragment" }}
{{- end }}
{{- if regexMatch "(?i)\\.local(:[0-9]{1,5})?$" .Values.baseUrl }}
{{- fail "baseUrl must not use the special-use .local namespace" }}
{{- end }}
{{- if not (has .Values.persistence.accessMode (list "ReadWriteOnce" "ReadWriteOncePod")) }}
{{- fail "persistence.accessMode must be ReadWriteOnce or ReadWriteOncePod for the single-writer SQLite volume" }}
{{- end }}
{{- if and (not (kindIs "invalid" .Values.retention.messageTtlDays)) (le (int .Values.retention.messageTtlDays) 0) }}
{{- fail "retention.messageTtlDays must be a positive integer when set" }}
{{- end }}
{{- if and (not (kindIs "invalid" .Values.mailbox.ttlMs)) (le (int .Values.mailbox.ttlMs) 0) }}
{{- fail "mailbox.ttlMs must be a positive integer when set" }}
{{- end }}
{{- if and (not (kindIs "invalid" .Values.mailbox.depthCap)) (le (int .Values.mailbox.depthCap) 0) }}
{{- fail "mailbox.depthCap must be a positive integer when set" }}
{{- end }}
{{- if and .Values.ingress.enabled (not .Values.ingress.hosts) }}
{{- fail "ingress.enabled=true requires at least one host" }}
{{- end }}
{{- if .Values.ingress.enabled }}
{{- $baseHost := regexReplaceAll ":[0-9]+$" (trimPrefix "https://" .Values.baseUrl) "" | lower }}
{{- $ingressHosts := list }}
{{- range .Values.ingress.hosts }}
{{- $ingressHosts = append $ingressHosts (lower .) }}
{{- end }}
{{- if not (has $baseHost $ingressHosts) }}
{{- fail "ingress.hosts must include the DNS host from baseUrl" }}
{{- end }}
{{- end }}
{{- if and .Values.ingress.enabled .Values.networkPolicy.enabled (not .Values.networkPolicy.ingressFrom) }}
{{- fail "ingress with networkPolicy requires networkPolicy.ingressFrom to allow the ingress controller explicitly" }}
{{- end }}
{{- range .Values.extraEnv }}
{{- if has .name (list "PORT" "RELAYCAST_DB_PATH" "RELAYCAST_WORKSPACE_BOOTSTRAP_SECRET" "RELAYCAST_WORKSPACE_BOOTSTRAP_PROOF_REQUIRED" "RELAYCAST_MESSAGE_TTL_DAYS" "RELAYCAST_MAILBOX_TTL_MS" "RELAYCAST_MAILBOX_DEPTH_CAP") }}
{{- if has .name (list "RELAYCAST_WORKSPACE_BOOTSTRAP_SECRET" "RELAYCAST_WORKSPACE_BOOTSTRAP_PROOF_REQUIRED") }}
{{- fail (printf "%s is not supported by the pinned Relaycast 8.0.0 image" .name) }}
{{- else }}
{{- fail (printf "%s is managed by structured chart values and must not appear in extraEnv" .name) }}
{{- end }}
{{- end }}
{{- end }}
{{- end }}
