{{/*
Engine environment. Secret values are only ever referenced, never rendered.
*/}}
{{- define "relaycast-cloud.server.env" -}}
- name: PORT
  value: {{ .Values.relaycast.port | quote }}
- name: RELAYCAST_ENV
  value: {{ .Values.relaycast.environment | quote }}
- name: RELAYCAST_DB_PATH
  value: {{ .Values.database.sqlite.path | quote }}
- name: RELAYCAST_WORKSPACE_BOOTSTRAP_PROOF_REQUIRED
  value: {{ .Values.relaycast.workspaces.bootstrapProofRequired | toString | quote }}
{{- with (include "relaycast-cloud.secretName" .) }}
- name: RELAYCAST_WORKSPACE_BOOTSTRAP_SECRET
  valueFrom:
    secretKeyRef:
      name: {{ . }}
      key: {{ $.Values.secrets.keys.workspaceBootstrapSecret }}
{{- end }}
{{- with .Values.relaycast.messageTtlDays }}
- name: RELAYCAST_MESSAGE_TTL_DAYS
  value: {{ . | quote }}
{{- end }}
{{- with .Values.relaycast.mailboxTtlMs }}
- name: RELAYCAST_MAILBOX_TTL_MS
  value: {{ . | quote }}
{{- end }}
{{- with .Values.relaycast.mailboxDepthCap }}
- name: RELAYCAST_MAILBOX_DEPTH_CAP
  value: {{ . | quote }}
{{- end }}
{{- with .Values.global.otel.endpoint }}
- name: OTEL_EXPORTER_OTLP_ENDPOINT
  value: {{ . | quote }}
- name: OTEL_SERVICE_NAME
  value: {{ include "relaycast-cloud.fullname" $ | quote }}
{{- end }}
{{- with .Values.extraEnv }}
{{ toYaml . }}
{{- end }}
{{- end }}
