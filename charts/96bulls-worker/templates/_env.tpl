{{/*
Fail early on missing required values (render time, not crash-loop time).
*/}}
{{- define "96bulls-worker.validate" -}}
{{- if not .Values.existingSecret }}{{ fail "96bulls-worker: existingSecret is required (Secret with HOOPDB_URL, LOCKER_ACCESS_KEY_ID, LOCKER_SECRET_ACCESS_KEY)" }}{{ end -}}
{{- if not .Values.locker.endpoint }}{{ fail "96bulls-worker: locker.endpoint is required" }}{{ end -}}
{{- if not .Values.tenant.orgId }}{{ fail "96bulls-worker: tenant.orgId is required" }}{{ end -}}
{{- $idx := index .Values.components "hoopdb-indexer" -}}
{{- if and $idx.enabled (gt (int $idx.replicas) 1) }}{{ fail "96bulls-worker: components.hoopdb-indexer.replicas must be 1 (manifest reconcile is not leader-elected)" }}{{ end -}}
{{- end }}

{{/*
Shared environment: the services' env contract (names must not change).
Usage: include "96bulls-worker.env" (dict "context" . "service" "referee")
*/}}
{{- define "96bulls-worker.env" -}}
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
{{- define "96bulls-worker.podSpecCommon" -}}
{{- include "96bulls-worker.pullSecrets" . }}
serviceAccountName: {{ include "96bulls-worker.serviceAccountName" . }}
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
