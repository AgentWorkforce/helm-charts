{{/*
Fail early on missing required values (render time, not crash-loop time).
*/}}
{{- define "alleyoop.validate" -}}
{{- if not .Values.existingSecret }}{{ fail "alleyoop: existingSecret is required (Secret with HOOPDB_URL, LOCKER_ACCESS_KEY_ID, LOCKER_SECRET_ACCESS_KEY)" }}{{ end -}}
{{- if not .Values.locker.endpoint }}{{ fail "alleyoop: locker.endpoint is required" }}{{ end -}}
{{- if not .Values.tenant.orgId }}{{ fail "alleyoop: tenant.orgId is required" }}{{ end -}}
{{- if and .Values.auth.jwksUrl .Values.auth.localJwks }}{{ fail "alleyoop: set auth.jwksUrl OR auth.localJwks, not both" }}{{ end -}}
{{- if not (or .Values.auth.jwksUrl .Values.auth.localJwks) }}{{ fail "alleyoop: set auth.jwksUrl (RelayAuth JWKS) or auth.localJwks=true (JWKS JSON from existingSecret, local/kind only)" }}{{ end -}}
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
      name: {{ $v.existingSecret }}
      key: {{ $v.secretKeys.hoopdbUrl }}
- name: LOCKER_ENDPOINT
  value: {{ $v.locker.endpoint | quote }}
- name: LOCKER_BUCKET
  value: {{ $v.locker.bucket | quote }}
- name: LOCKER_REGION
  value: {{ $v.locker.region | quote }}
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
- name: TENANT_ORG_ID
  value: {{ $v.tenant.orgId | quote }}
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
