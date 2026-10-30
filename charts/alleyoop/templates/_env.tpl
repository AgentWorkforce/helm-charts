{{/*
Tenant org id: tenant.orgId, else global.tenant.orgId (set once by an umbrella).
*/}}
{{- define "alleyoop.orgId" -}}
{{- .Values.tenant.orgId | default (dig "tenant" "orgId" "" (.Values.global | default dict)) -}}
{{- end }}

{{/*
Fail early on missing required values (render time, not crash-loop time).
*/}}
{{- define "alleyoop.validate" -}}
{{- $credentialsMode := .Values.locker.credentials.mode | default "secret" -}}
{{- if not (or (eq $credentialsMode "secret") (eq $credentialsMode "podIdentity")) }}{{ fail "alleyoop: locker.credentials.mode must be secret or podIdentity" }}{{ end -}}
{{- if and (eq $credentialsMode "secret") (not .Values.existingSecret) }}{{ fail "alleyoop: existingSecret is required when locker.credentials.mode=secret" }}{{ end -}}
{{- if and (not .Values.hoopdb.existingSecret) (not .Values.existingSecret) }}{{ fail "alleyoop: hoopdb.existingSecret or existingSecret is required for HOOPDB_URL" }}{{ end -}}
{{- if and (eq $credentialsMode "secret") (not .Values.locker.endpoint) }}{{ fail "alleyoop: locker.endpoint is required when locker.credentials.mode=secret" }}{{ end -}}
{{- if not (include "alleyoop.orgId" .) }}{{ fail "alleyoop: tenant.orgId (or global.tenant.orgId) is required" }}{{ end -}}
{{- if and .Values.auth.jwksUrl .Values.auth.localJwks }}{{ fail "alleyoop: set auth.jwksUrl OR auth.localJwks, not both" }}{{ end -}}
{{- if not (or .Values.auth.jwksUrl .Values.auth.localJwks) }}{{ fail "alleyoop: set auth.jwksUrl (RelayAuth JWKS) or auth.localJwks=true (JWKS JSON from existingSecret, local/kind only)" }}{{ end -}}
{{- if and .Values.auth.localJwks (not .Values.existingSecret) }}{{ fail "alleyoop: existingSecret is required when auth.localJwks=true" }}{{ end -}}
{{- if not (kindIs "bool" .Values.auth.allowInterimRelayAuthBearer) }}{{ fail "alleyoop: auth.allowInterimRelayAuthBearer must be a boolean" }}{{ end -}}
{{- if and .Values.auth.allowInterimRelayAuthBearer (ne .Values.environment "local") }}{{ fail "alleyoop: auth.allowInterimRelayAuthBearer=true is allowed only when environment=local" }}{{ end -}}
{{- range $entry := .Values.extraEnv }}
{{- if eq ($entry.name | default "") "ALLOW_INTERIM_RELAYAUTH_BEARER" }}{{ fail "alleyoop: configure auth.allowInterimRelayAuthBearer instead of extraEnv" }}{{ end -}}
{{- end -}}
{{- range $entry := .Values.ingest.env }}
{{- if eq ($entry.name | default "") "ALLOW_INTERIM_RELAYAUTH_BEARER" }}{{ fail "alleyoop: configure auth.allowInterimRelayAuthBearer instead of ingest.env" }}{{ end -}}
{{- end -}}
{{- end }}

{{/*
Shared environment: the services' env contract (names must not change).
Usage: include "alleyoop.env" (dict "context" . "service" "referee")
*/}}
{{- define "alleyoop.env" -}}
{{- $v := .context.Values -}}
- name: SERVICE
  value: {{ .service | quote }}
- name: OTEL_SERVICE_NAME
  value: {{ .service | quote }}
- name: HOOPDB_URL
  valueFrom:
    secretKeyRef:
      name: {{ $v.hoopdb.existingSecret | default $v.existingSecret }}
      key: {{ $v.hoopdb.key | default $v.secretKeys.hoopdbUrl }}
- name: LOCKER_ENDPOINT
  value: {{ $v.locker.endpoint | quote }}
- name: LOCKER_BUCKET
  value: {{ $v.locker.bucket | quote }}
- name: LOCKER_REGION
  value: {{ $v.locker.region | quote }}
{{- if eq ($v.locker.credentials.mode | default "secret") "secret" }}
- name: LOCKER_ACCESS_KEY_ID
  valueFrom:
    secretKeyRef:
      name: {{ $v.existingSecret }}
      key: {{ $v.secretKeys.lockerAccessKeyId }}
- name: LOCKER_SECRET_ACCESS_KEY
  valueFrom:
    secretKeyRef:
      name: {{ $v.existingSecret }}
      key: {{ $v.secretKeys.lockerSecretAccessKey }}
{{- end }}
- name: TENANT_ORG_ID
  value: {{ include "alleyoop.orgId" .context | quote }}
- name: WORKSPACE_ID
  value: {{ $v.tenant.workspaceId | quote }}
- name: DEPLOYMENT
  value: {{ $v.deployment.name | quote }}
- name: DEPLOYMENT_ID
  value: {{ $v.deployment.id | default (printf "%s/%s" .context.Release.Namespace .context.Release.Name) | quote }}
- name: ENVIRONMENT
  value: {{ $v.environment | quote }}
{{- if $v.global.otel.endpoint }}
- name: OTEL_EXPORTER_OTLP_ENDPOINT
  value: {{ $v.global.otel.endpoint | quote }}
{{- else }}
# The image bakes a local-stack collector address; blank it so the SDK does
# not export anywhere unless an endpoint is configured.
- name: OTEL_EXPORTER_OTLP_ENDPOINT
  value: ""
{{- end }}
- name: TMPDIR
  value: /tmp
{{- with $v.extraEnv }}
{{ toYaml . }}
{{- end }}
{{- end }}

{{/*
Pod-level boilerplate shared by every workload and Job.
*/}}
{{- define "alleyoop.podSpecCommon" -}}
{{- include "alleyoop.pullSecrets" . }}
serviceAccountName: {{ include "alleyoop.serviceAccountName" . }}
automountServiceAccountToken: {{ .Values.automountServiceAccountToken }}
{{- with .Values.podSecurityContext }}
securityContext:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with .Values.nodeSelector }}
nodeSelector:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with .Values.tolerations }}
tolerations:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with .Values.affinity }}
affinity:
  {{- toYaml . | nindent 2 }}
{{- end }}
volumes:
  - name: tmp
    emptyDir: {}
{{- end }}
