{{/*
Job spec, rendered once so its exact text can be hashed into the Job name.
*/}}
{{- define "96bulls-worker.jobSpec" -}}
{{- $ := .context -}}
{{- $component := .service -}}
backoffLimit: {{ .config.backoffLimit }}
activeDeadlineSeconds: {{ .config.activeDeadlineSeconds }}
{{- if .config.ttlSecondsAfterFinished }}
ttlSecondsAfterFinished: {{ .config.ttlSecondsAfterFinished }}
{{- end }}
template:
  metadata:
    labels:
      {{- include "96bulls-worker.componentSelectorLabels" (dict "context" $ "component" $component) | nindent 6 }}
      {{- with $.Values.podLabels }}
      {{- toYaml . | nindent 6 }}
      {{- end }}
    {{- with $.Values.podAnnotations }}
    annotations:
      {{- toYaml . | nindent 6 }}
    {{- end }}
  spec:
    restartPolicy: Never
    {{- include "96bulls-worker.podSpecCommon" $ | nindent 4 }}
    containers:
      - name: {{ .job }}
        image: {{ include "96bulls-worker.image" $ | quote }}
        imagePullPolicy: {{ $.Values.image.pullPolicy }}
        env:
          {{- include "96bulls-worker.env" (dict "context" $ "service" .service) | nindent 10 }}
          {{- if eq .job "migrate" }}
          - name: HOOPDB_SUPABASE_SHIM
            value: {{ ternary "true" "false" $.Values.migrations.supabaseShim | quote }}
          {{- end }}
        {{- with $.Values.containerSecurityContext }}
        securityContext:
          {{- toYaml . | nindent 10 }}
        {{- end }}
        {{- with .config.resources }}
        resources:
          {{- toYaml . | nindent 10 }}
        {{- end }}
        volumeMounts:
          - name: tmp
            mountPath: /tmp
{{- end }}
