{{- define "relay-cloud-api.name" -}}{{ default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}{{- end -}}
{{- define "relay-cloud-api.fullname" -}}{{ if .Values.fullnameOverride }}{{ .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}{{ else }}{{ printf "%s-%s" .Release.Name (include "relay-cloud-api.name" .) | trunc 63 | trimSuffix "-" }}{{ end }}{{- end -}}
{{- define "relay-cloud-api.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
{{ include "relay-cloud-api.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: agent-relay
{{- end -}}
{{- /* Job metadata labels: the runtime component label is replaced by
migration so `kubectl wait job -l app.kubernetes.io/component=migration`
(NOTES.txt) finds the Job. */ -}}
{{- define "relay-cloud-api.migrationLabels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
app.kubernetes.io/name: {{ include "relay-cloud-api.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: migration
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: agent-relay
{{- end -}}
{{- define "relay-cloud-api.selectorLabels" -}}
app.kubernetes.io/name: {{ include "relay-cloud-api.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: api
{{- end -}}
{{- define "relay-cloud-api.serviceAccountName" -}}{{ if .Values.serviceAccount.create }}{{ default (include "relay-cloud-api.fullname" .) .Values.serviceAccount.name }}{{ else }}{{ default "default" .Values.serviceAccount.name }}{{ end }}{{- end -}}
{{- define "relay-cloud-api.image" -}}
{{- $digest := required "image.digest is required; relay-cloud-api images must be pinned by sha256 digest" .Values.image.digest -}}
{{- if not (regexMatch "^sha256:[a-f0-9]{64}$" $digest) }}{{ fail "image.digest must be sha256:<64 lowercase hex characters>" }}{{ end -}}
{{- printf "%s@%s" .Values.image.repository $digest -}}
{{- end -}}
{{- define "relay-cloud-api.validate" -}}
{{- $image := include "relay-cloud-api.image" . -}}
{{- if ne (int .Values.replicaCount) 1 }}{{ fail "replicaCount must be 1: the self-host API pilot has process-local login/device rate limits and is not HA" }}{{ end -}}
{{- if not .Values.existingSecret }}{{ fail "existingSecret is required; inline credentials are not supported" }}{{ end -}}
{{- range $name, $key := .Values.secretKeys }}{{ if not (regexMatch "^[A-Za-z0-9._-]+$" (toString $key)) }}{{ fail (printf "secretKeys.%s must be a Kubernetes Secret data key" $name) }}{{ end }}{{ end -}}
{{- if and .Values.migrations.enabled (not (regexMatch "^[A-Za-z_][A-Za-z0-9_$]{0,62}$" .Values.database.runtimeRole)) }}{{ fail "database.runtimeRole must be a valid PostgreSQL role name when migrations are enabled" }}{{ end -}}
{{- if not (regexMatch "^https://[^/?#]+$" .Values.publicUrl) }}{{ fail "publicUrl must be an HTTPS origin with no path" }}{{ end -}}
{{- range $name, $url := dict "relayauthUrl" .Values.services.relayauthUrl "relaycastUrl" .Values.services.relaycastUrl "relayhistoryUrl" .Values.services.relayhistoryUrl }}{{ if not (regexMatch "^https?://[^/?#]+$" $url) }}{{ fail (printf "services.%s must be an HTTP(S) origin with no path" $name) }}{{ end }}{{ end -}}
{{- $publicOriginPattern := "^https://([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\\.)+[A-Za-z]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(:[0-9]{1,5})?$" -}}
{{- range $name, $url := dict "relaycastPublicUrl" .Values.services.relaycastPublicUrl "relayhistoryPublicUrl" .Values.services.relayhistoryPublicUrl -}}
{{- if or (not (regexMatch $publicOriginPattern $url)) (regexMatch "(?i)\\.(localhost|local|internal|lan|invalid|test|example|home\\.arpa|onion)(:[0-9]{1,5})?$" $url) (regexMatch "(?i)\\.example\\.(com|net|org)(:[0-9]{1,5})?$" $url) }}{{ fail (printf "services.%s must be a public HTTPS origin with multi-label DNS and no credentials, path, query, or fragment" $name) }}{{ end -}}
{{- $portToken := regexFind ":[0-9]+$" $url -}}
{{- if and $portToken (or (lt (int (trimPrefix ":" $portToken)) 1) (gt (int (trimPrefix ":" $portToken)) 65535)) }}{{ fail (printf "services.%s port must be between 1 and 65535" $name) }}{{ end -}}
{{- end -}}
{{- if and .Values.networkPolicy.enabled (not .Values.networkPolicy.allowAllEgress) (empty .Values.networkPolicy.additionalEgress) }}{{ fail "networkPolicy.enabled with allowAllEgress=false requires networkPolicy.additionalEgress: restricted egress allows only same-namespace pods and DNS, which blocks the external PostgreSQL database and any RelayAuth, Relaycast or Relay History URL outside the namespace" }}{{ end -}}
{{- range .Values.networkPolicy.additionalEgress }}{{ if empty .to }}{{ fail "every networkPolicy.additionalEgress rule needs a non-empty to (an empty to matches every destination; use ipBlock 0.0.0.0/0 to allow any destination explicitly)" }}{{ end }}{{ end -}}
{{- if ne .Values.service.type "ClusterIP" }}{{ fail "service.type must be ClusterIP" }}{{ end -}}
{{- if .Values.ingress.enabled }}{{ if empty .Values.ingress.hosts }}{{ fail "ingress.enabled=true requires at least one host" }}{{ end }}{{ if and (not .Values.ingress.externalTls) (empty .Values.ingress.tls) }}{{ fail "ingress.enabled=true requires ingress.tls unless externalTls=true" }}{{ end }}{{ if and .Values.networkPolicy.enabled (empty .Values.networkPolicy.ingressFrom) }}{{ fail "ingress with networkPolicy requires networkPolicy.ingressFrom" }}{{ end }}{{ end -}}
{{- end -}}
{{- define "relay-cloud-api.secretEnv" -}}
{{- range $env, $key := dict "DATABASE_URL_FILE" .Values.secretKeys.databaseUrl "RELAYAUTH_API_KEY_FILE" .Values.secretKeys.relayauthApiKey "SELFHOST_BOOTSTRAP_TOKEN_FILE" .Values.secretKeys.bootstrapToken "SELFHOST_ENCRYPTION_KEY_FILE" .Values.secretKeys.encryptionKey }}
- name: {{ $env }}
  value: /var/run/agent-relay/secrets/{{ $key }}
{{- end }}
{{- end -}}
{{- define "relay-cloud-api.migrationPodTemplate" -}}
metadata:
  labels:
    app.kubernetes.io/name: {{ include "relay-cloud-api.name" . }}
    app.kubernetes.io/instance: {{ .Release.Name }}
    app.kubernetes.io/component: migration
spec:
  restartPolicy: Never
  serviceAccountName: {{ include "relay-cloud-api.serviceAccountName" . }}
  automountServiceAccountToken: false
  securityContext: {{ toYaml .Values.podSecurityContext | nindent 4 }}
  {{- with .Values.imagePullSecrets }}
  imagePullSecrets: {{ toYaml . | nindent 4 }}
  {{- end }}
  containers:
    - name: migrate
      image: {{ include "relay-cloud-api.image" . | quote }}
      imagePullPolicy: {{ .Values.image.pullPolicy }}
      command: {{ toYaml .Values.migrations.command | nindent 8 }}
      args: {{ toYaml .Values.migrations.args | nindent 8 }}
      securityContext: {{ toYaml .Values.containerSecurityContext | nindent 8 }}
      env:
        - name: DATABASE_MIGRATIONS_URL_FILE
          value: /var/run/agent-relay/secrets/{{ .Values.secretKeys.databaseMigrationsUrl }}
        - name: SELFHOST_RUNTIME_DATABASE_ROLE
          value: {{ .Values.database.runtimeRole | quote }}
      volumeMounts:
        - { name: database, mountPath: /var/run/agent-relay/secrets, readOnly: true }
        - { name: tmp, mountPath: /tmp }
      resources: {{ toYaml .Values.resources | nindent 8 }}
  volumes:
    - name: database
      secret:
        secretName: {{ .Values.existingSecret }}
        defaultMode: 0440
        items:
          - key: {{ .Values.secretKeys.databaseMigrationsUrl | quote }}
            path: {{ .Values.secretKeys.databaseMigrationsUrl | quote }}
    - name: tmp
      emptyDir: { sizeLimit: 64Mi }
{{- end -}}
