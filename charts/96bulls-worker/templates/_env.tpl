{{/*
Tenant org id: tenant.orgId, else global.tenant.orgId (set once by an umbrella).
*/}}
{{- define "96bulls-worker.orgId" -}}
{{- .Values.tenant.orgId | default (dig "tenant" "orgId" "" (.Values.global | default dict)) -}}
{{- end }}

{{/*
Fail early on missing required values (render time, not crash-loop time).
*/}}
{{- define "96bulls-worker.validate" -}}
{{- $credentialsMode := .Values.locker.credentials.mode | default "secret" -}}
{{- if not (or (eq $credentialsMode "secret") (eq $credentialsMode "podIdentity")) }}{{ fail "96bulls-worker: locker.credentials.mode must be secret or podIdentity" }}{{ end -}}
{{- if and (eq $credentialsMode "secret") (not .Values.existingSecret) }}{{ fail "96bulls-worker: existingSecret is required when locker.credentials.mode=secret" }}{{ end -}}
{{- if and (not .Values.hoopdb.existingSecret) (not .Values.existingSecret) }}{{ fail "96bulls-worker: hoopdb.existingSecret or existingSecret is required for HOOPDB_URL" }}{{ end -}}
{{- if and (eq $credentialsMode "secret") (not .Values.locker.endpoint) }}{{ fail "96bulls-worker: locker.endpoint is required when locker.credentials.mode=secret" }}{{ end -}}
{{- if not (include "96bulls-worker.orgId" .) }}{{ fail "96bulls-worker: tenant.orgId (or global.tenant.orgId) is required" }}{{ end -}}
{{- $idx := index .Values.components "hoopdb-indexer" -}}
{{- if and $idx.enabled (gt (int $idx.replicas) 1) }}{{ fail "96bulls-worker: components.hoopdb-indexer.replicas must be 1 (manifest reconcile is not leader-elected)" }}{{ end -}}
{{- $bob := index .Values.components "bob-costas" -}}
{{- if and $bob.enabled (not (.Values.summaryEncryption.existingSecret | default .Values.existingSecret)) }}{{ fail "96bulls-worker: summaryEncryption.existingSecret or existingSecret is required when bob-costas is enabled" }}{{ end -}}
{{- if and $bob.enabled (not .Values.summaryEncryption.key) }}{{ fail "96bulls-worker: summaryEncryption.key is required when bob-costas is enabled" }}{{ end -}}
{{- if and $bob.enabled (not .Values.summaryEncryption.mountPath) }}{{ fail "96bulls-worker: summaryEncryption.mountPath is required when bob-costas is enabled" }}{{ end -}}
{{- if and $bob.enabled (not .Values.summaryEncryption.fileName) }}{{ fail "96bulls-worker: summaryEncryption.fileName is required when bob-costas is enabled" }}{{ end -}}
{{- range $entry := $bob.env }}
{{- if or (eq ($entry.name | default "") "SUMMARY_MASTER_KEYS") (eq ($entry.name | default "") "SUMMARY_MASTER_KEYS_FILE") }}{{ fail "96bulls-worker: configure summaryEncryption instead of components.bob-costas.env SUMMARY_MASTER_KEYS/SUMMARY_MASTER_KEYS_FILE" }}{{ end -}}
{{- end }}
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
  value: {{ include "96bulls-worker.orgId" .context | quote }}
- name: WORKSPACE_ID
  value: {{ $v.tenant.workspaceId | quote }}
- name: DEPLOYMENT
  value: {{ $v.deployment.name | quote }}
- name: DEPLOYMENT_ID
  value: {{ $v.deployment.id | default (printf "%s/%s" .context.Release.Namespace .context.Release.Name) | quote }}
- name: ENVIRONMENT
  value: {{ $v.environment | quote }}
{{- if eq .service "bob-costas" }}
# The Secret is projected as a file into Bob Costas only; the key material is
# never copied into the Pod spec's environment values.
- name: SUMMARY_MASTER_KEYS_FILE
  value: {{ printf "%s/%s" $v.summaryEncryption.mountPath $v.summaryEncryption.fileName | quote }}
{{- end }}
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
{{- $ctx := .context -}}
{{- include "96bulls-worker.pullSecrets" $ctx }}
serviceAccountName: {{ include "96bulls-worker.serviceAccountName" $ctx }}
automountServiceAccountToken: {{ $ctx.Values.automountServiceAccountToken }}
{{- with $ctx.Values.podSecurityContext }}
securityContext:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with $ctx.Values.nodeSelector }}
nodeSelector:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with $ctx.Values.tolerations }}
tolerations:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with $ctx.Values.affinity }}
affinity:
  {{- toYaml . | nindent 2 }}
{{- end }}
volumes:
  - name: tmp
    emptyDir: {}
{{- if eq .component "bob-costas" }}
  - name: summary-master-keys
    secret:
      secretName: {{ $ctx.Values.summaryEncryption.existingSecret | default $ctx.Values.existingSecret | quote }}
      # Kubernetes projects this for the Pod's fsGroup: Bob can read it, but
      # it is not world-readable inside the Pod.
      defaultMode: 0440
      items:
        - key: {{ $ctx.Values.summaryEncryption.key | quote }}
          path: {{ $ctx.Values.summaryEncryption.fileName | quote }}
{{- end }}
{{- end }}
