{{- define "relayhistory.name" -}}{{ default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}{{- end -}}
{{- define "relayhistory.fullname" -}}{{ if .Values.fullnameOverride }}{{ .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}{{ else }}{{ printf "%s-%s" .Release.Name (include "relayhistory.name" .) | trunc 63 | trimSuffix "-" }}{{ end }}{{- end -}}
{{- define "relayhistory.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
{{ include "relayhistory.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: agent-relay
{{- end -}}
{{- define "relayhistory.selectorLabels" -}}
app.kubernetes.io/name: {{ include "relayhistory.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: history
{{- end -}}
{{- define "relayhistory.serviceAccountName" -}}{{ if .Values.serviceAccount.create }}{{ default (include "relayhistory.fullname" .) .Values.serviceAccount.name }}{{ else }}{{ default "default" .Values.serviceAccount.name }}{{ end }}{{- end -}}
{{- define "relayhistory.image" -}}
{{- $digest := required "image.digest is required; relayhistory images must be pinned by sha256 digest" .Values.image.digest -}}
{{- if not (regexMatch "^sha256:[a-f0-9]{64}$" $digest) }}{{ fail "image.digest must be sha256:<64 lowercase hex characters>" }}{{ end -}}
{{- printf "%s@%s" .Values.image.repository $digest -}}
{{- end -}}
{{- define "relayhistory.validate" -}}
{{- $image := include "relayhistory.image" . -}}
{{- if ne (int .Values.replicaCount) 1 }}{{ fail "replicaCount must be 1: the GCP proof runs one History replica and the chart makes no HA claim" }}{{ end -}}
{{- if not .Values.database.existingSecret }}{{ fail "database.existingSecret is required; the chart never creates database credentials" }}{{ end -}}
{{- range $name, $key := .Values.database.keys }}{{ if not (regexMatch "^[A-Za-z0-9._-]+$" (toString $key)) }}{{ fail (printf "database.keys.%s must be a Kubernetes Secret data key" $name) }}{{ end }}{{ end -}}
{{- if and .Values.database.runtimeRole (not (regexMatch "^[A-Za-z_][A-Za-z0-9_$]{0,62}$" .Values.database.runtimeRole)) }}{{ fail "database.runtimeRole must be a valid PostgreSQL role name" }}{{ end -}}
{{- if not (regexMatch "^https://[^/?#]+$" .Values.relayauth.historyOrigin) }}{{ fail "relayauth.historyOrigin must be an HTTPS origin with no path" }}{{ end -}}
{{- if not (regexMatch "^https?://[^?#]+$" .Values.relayauth.jwksUrl) }}{{ fail "relayauth.jwksUrl is required" }}{{ end -}}
{{- if not (regexMatch "^https?://[^/?#]+$" .Values.relayauth.issuer) }}{{ fail "relayauth.issuer must be an HTTP(S) origin" }}{{ end -}}
{{- if not (regexMatch "^https?://[^?#]+$" .Values.agentRelayCloud.apiUrl) }}{{ fail "agentRelayCloud.apiUrl is required" }}{{ end -}}
{{- if ne .Values.service.type "ClusterIP" }}{{ fail "service.type must be ClusterIP" }}{{ end -}}
{{- if and .Values.telemetry.enabled (not .Values.telemetry.host) }}{{ fail "telemetry.host is required when telemetry.enabled=true" }}{{ end -}}
{{- range $name, $feature := dict "embeddings" .Values.embeddings "sessionAnalysis" .Values.sessionAnalysis "telemetry" .Values.telemetry }}{{ if and $feature.enabled (not (regexMatch "^[A-Za-z0-9._-]+$" (toString $feature.key))) }}{{ fail (printf "%s.key must name a Secret data key when %s.enabled=true" $name $name) }}{{ end }}{{ end -}}
{{- if and .Values.migrations.enabled (lt (int .Values.migrations.activeDeadlineSeconds) (add (int .Values.migrations.rolloutBudgetSeconds) 2700 | int)) }}{{ fail "migrations.activeDeadlineSeconds must be >= rolloutBudgetSeconds + 2700" }}{{ end -}}
{{- if .Values.ingress.enabled }}{{ if empty .Values.ingress.hosts }}{{ fail "ingress.enabled=true requires at least one host" }}{{ end }}{{ if and (not .Values.ingress.externalTls) (empty .Values.ingress.tls) }}{{ fail "ingress.enabled=true requires ingress.tls unless externalTls=true" }}{{ end }}{{ if and .Values.networkPolicy.enabled (empty .Values.networkPolicy.ingressFrom) }}{{ fail "ingress with networkPolicy requires networkPolicy.ingressFrom" }}{{ end }}{{ end -}}
{{- $reservedEnv := list "PORT" "ENVIRONMENT" "MAX_BODY_BYTES" "MAX_INFLIGHT_BODY_BYTES" "SHUTDOWN_GRACE_MS" "SHUTDOWN_DRAIN_DELAY_MS" "PG_POOL_MAX" "CRON_ENABLED" "RELAYAUTH_JWKS_URL" "RELAYAUTH_ISSUER" "RELAYAUTH_AUDIENCE" "RELAYHISTORY_ORIGIN" "AGENT_RELAY_CLOUD_API_URL" "SESSION_EVENTS_ENABLED" "POSTHOG_HOST" "DATABASE_URL" "DATABASE_MIGRATIONS_URL" "DATABASE_RUNTIME_ROLE" "EMBEDDING_API_KEY" "OPENAI_API_KEY" "POSTHOG_API_KEY" "ALLOW_WRITE_HOLD" "ROLLOUT_BUDGET_SECONDS" -}}
{{- range .Values.extraEnv }}{{ if has .name $reservedEnv }}{{ fail (printf "%s is managed by structured chart values and must not appear in extraEnv" .name) }}{{ end }}{{ end -}}
{{- range .Values.extraEnvFrom }}{{ if has .name $reservedEnv }}{{ fail (printf "%s is managed by structured chart values and must not appear in extraEnvFrom" .name) }}{{ end }}{{ end -}}
{{- range $key, $_ := .Values.extraConfig }}{{ if has $key $reservedEnv }}{{ fail (printf "%s is managed by structured chart values and must not appear in extraConfig" $key) }}{{ end }}{{ end -}}
{{- end -}}
{{- define "relayhistory.secretEnv" -}}
- name: DATABASE_URL
  valueFrom:
    secretKeyRef:
      name: {{ .Values.database.existingSecret }}
      key: {{ .Values.database.keys.url | quote }}
{{- if .Values.embeddings.enabled }}
- name: EMBEDDING_API_KEY
  valueFrom:
    secretKeyRef:
      name: {{ default .Values.database.existingSecret .Values.embeddings.existingSecret }}
      key: {{ .Values.embeddings.key | quote }}
{{- end }}
{{- if .Values.sessionAnalysis.enabled }}
- name: OPENAI_API_KEY
  valueFrom:
    secretKeyRef:
      name: {{ default .Values.database.existingSecret .Values.sessionAnalysis.existingSecret }}
      key: {{ .Values.sessionAnalysis.key | quote }}
{{- end }}
{{- if .Values.telemetry.enabled }}
- name: POSTHOG_API_KEY
  valueFrom:
    secretKeyRef:
      name: {{ default .Values.database.existingSecret .Values.telemetry.existingSecret }}
      key: {{ .Values.telemetry.key | quote }}
{{- end }}
{{- end -}}
{{- define "relayhistory.migrationPodTemplate" -}}
metadata:
  labels:
    app.kubernetes.io/name: {{ include "relayhistory.name" . }}
    app.kubernetes.io/instance: {{ .Release.Name }}
    app.kubernetes.io/component: migration
spec:
  restartPolicy: Never
  serviceAccountName: {{ include "relayhistory.serviceAccountName" . }}
  automountServiceAccountToken: false
  securityContext: {{ toYaml .Values.podSecurityContext | nindent 4 }}
  {{- with .Values.imagePullSecrets }}
  imagePullSecrets: {{ toYaml . | nindent 4 }}
  {{- end }}
  containers:
    - name: migrate
      image: {{ include "relayhistory.image" . | quote }}
      imagePullPolicy: {{ .Values.image.pullPolicy }}
      args: [migrate.mjs]
      securityContext: {{ toYaml .Values.containerSecurityContext | nindent 8 }}
      env:
        - name: DATABASE_MIGRATIONS_URL
          valueFrom:
            secretKeyRef:
              name: {{ .Values.database.existingSecret }}
              key: {{ .Values.database.keys.migrationsUrl | quote }}
        - name: DATABASE_URL
          valueFrom:
            secretKeyRef:
              name: {{ .Values.database.existingSecret }}
              key: {{ .Values.database.keys.url | quote }}
        {{- with .Values.database.runtimeRole }}
        - { name: DATABASE_RUNTIME_ROLE, value: {{ . | quote }} }
        {{- end }}
        - { name: ALLOW_WRITE_HOLD, value: {{ ternary "yes" "no" .Values.migrations.allowWriteHold | quote }} }
        - { name: ROLLOUT_BUDGET_SECONDS, value: {{ .Values.migrations.rolloutBudgetSeconds | quote }} }
      resources: {{ toYaml .Values.resources | nindent 8 }}
      volumeMounts:
        - { name: tmp, mountPath: /tmp }
  volumes:
    - name: tmp
      emptyDir: { sizeLimit: 64Mi }
{{- end -}}
