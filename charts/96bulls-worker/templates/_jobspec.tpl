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
    {{- include "96bulls-worker.podSpecCommon" (dict "context" $ "component" .service) | nindent 4 }}
    {{- if and (eq .job "migrate") .config.waitForRole.enabled }}
    {{- $w := .config.waitForRole }}
    {{- if not (regexMatch "^[^@]+@sha256:[0-9a-f]{64}$" $w.image) }}{{ fail "96bulls-worker: migrations.waitForRole.image must be a full image reference with @sha256:<64 hex>" }}{{ end }}
    {{- if not (regexMatch "^[a-z_][a-z0-9_]*$" $w.role) }}{{ fail "96bulls-worker: migrations.waitForRole.role must be a plain lower-case role name" }}{{ end }}
    initContainers:
      # Runs before migrate: blocks until the role exists in HoopDb.
      - name: wait-for-role
        image: {{ $w.image | quote }}
        imagePullPolicy: IfNotPresent
        env:
          {{- include "96bulls-worker.hoopdbUrlEnv" $ | nindent 10 }}
          - { name: ROLE, value: {{ $w.role | quote }} }
          - { name: INTERVAL, value: {{ $w.intervalSeconds | quote }} }
          - { name: HOME, value: /tmp }
        command: ["/bin/sh", "-c"]
        args:
          - |
            set -u
            q="SELECT 1 FROM pg_roles WHERE rolname = '${ROLE}'"
            until [ "$(psql "$HOOPDB_URL" -X -At -c "$q" 2>/dev/null)" = 1 ]; do
              echo "wait-for-role: ${ROLE} not present yet"
              sleep "$INTERVAL"
            done
            echo "wait-for-role: ${ROLE} present"
        {{- with $.Values.containerSecurityContext }}
        securityContext:
          {{- toYaml . | nindent 10 }}
        {{- end }}
        resources:
          {{- toYaml $w.resources | nindent 10 }}
        volumeMounts:
          - name: tmp
            mountPath: /tmp
    {{- end }}
    containers:
      - name: {{ .job }}
        image: {{ include "96bulls-worker.image" $ | quote }}
        imagePullPolicy: {{ $.Values.image.pullPolicy }}
        env:
          {{- include "96bulls-worker.env" (dict "context" $ "service" .service) | nindent 10 }}
          {{- if eq .job "migrate" }}
          - name: HOOPDB_SUPABASE_SHIM
            value: {{ ternary "true" "false" $.Values.migrations.supabaseShim | quote }}
          # Always on: readiness needs the phase 2 PASS marker this run writes.
          - name: HOOPDB_ROLE_VERIFY
            value: "true"
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
