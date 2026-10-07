{{/*
Standalone Job spec, shared by the per-revision Job and by the CronJob's
jobTemplate so both run an identical pod. Rendered at column zero; callers
indent it.
*/}}
{{- define "relayflows.standaloneJobSpec" -}}
{{- if not (hasPrefix "/" .Values.standalone.dataDir) -}}
{{- fail "standalone.dataDir must be an absolute path" -}}
{{- end -}}
{{- if and .Values.standalone.localAgent (or (lt (int .Values.standalone.agentCapacity) 1) (gt (int .Values.standalone.agentCapacity) 32)) -}}
{{- fail "standalone.agentCapacity must be between 1 and 32 when standalone.localAgent=true" -}}
{{- end -}}
{{- range .Values.extraEnv -}}
{{- if or (eq .name "FLOWS_CLOUD_MIRROR") (eq .name "AGENT_RELAY_TELEMETRY_DISABLED") -}}
{{- fail (printf "extraEnv may not override %s in standalone mode" .name) -}}
{{- end -}}
{{- end -}}
{{- if and (ne .Values.standalone.activeDeadlineSeconds nil) (lt (int .Values.standalone.activeDeadlineSeconds) 1) -}}
{{- fail "standalone.activeDeadlineSeconds must be at least 1 when set" -}}
{{- end -}}
{{- if and (ne .Values.standalone.ttlSecondsAfterFinished nil) (lt (int .Values.standalone.ttlSecondsAfterFinished) 0) -}}
{{- fail "standalone.ttlSecondsAfterFinished must not be negative" -}}
{{- end -}}
backoffLimit: {{ .Values.standalone.backoffLimit }}
{{- if ne .Values.standalone.activeDeadlineSeconds nil }}
activeDeadlineSeconds: {{ .Values.standalone.activeDeadlineSeconds }}
{{- end }}
{{- if ne .Values.standalone.ttlSecondsAfterFinished nil }}
ttlSecondsAfterFinished: {{ .Values.standalone.ttlSecondsAfterFinished }}
{{- end }}
template:
  metadata:
    {{- with .Values.podAnnotations }}
    annotations:
      {{- toYaml . | nindent 6 }}
    {{- end }}
    labels:
      {{- with .Values.podLabels }}
      {{- toYaml . | nindent 6 }}
      {{- end }}
      {{- include "relayflows.selectorLabels" . | nindent 6 }}
  spec:
    restartPolicy: Never
    serviceAccountName: {{ include "relayflows.serviceAccountName" . }}
    automountServiceAccountToken: {{ .Values.serviceAccount.automountServiceAccountToken }}
    terminationGracePeriodSeconds: {{ .Values.standalone.terminationGracePeriodSeconds }}
    {{- with .Values.imagePullSecrets }}
    imagePullSecrets:
      {{- toYaml . | nindent 6 }}
    {{- end }}
    {{- with .Values.podSecurityContext }}
    securityContext:
      {{- toYaml . | nindent 6 }}
    {{- end }}
    {{- if or .Values.runtimeInstaller.enabled .Values.extraInitContainers }}
    initContainers:
      {{- if .Values.runtimeInstaller.enabled }}
      - name: install-runtime
        image: {{ include "relayflows.image" . }}
        imagePullPolicy: {{ .Values.image.pullPolicy }}
        command: [/bin/sh, -ec]
        args:
          - >-
            npm install --global --prefix /opt/relayflows-runtime
            --ignore-scripts --no-audit --no-fund
            "relayflows@${RELAYFLOWS_VERSION}"
        env:
          - name: RELAYFLOWS_VERSION
            value: {{ .Values.runtimeInstaller.relayflowsVersion | quote }}
          - name: HOME
            value: /tmp
          - name: NPM_CONFIG_CACHE
            value: /tmp/npm-cache
        {{- with .Values.containerSecurityContext }}
        securityContext:
          {{- toYaml . | nindent 10 }}
        {{- end }}
        {{- with .Values.runtimeInstaller.resources }}
        resources:
          {{- toYaml . | nindent 10 }}
        {{- end }}
        volumeMounts:
          - name: runtime
            mountPath: /opt/relayflows-runtime
          - name: tmp
            mountPath: /tmp
      {{- end }}
      {{- with .Values.extraInitContainers }}
      {{- toYaml . | nindent 6 }}
      {{- end }}
    {{- end }}
    containers:
      - name: runner
        image: {{ include "relayflows.image" . }}
        imagePullPolicy: {{ .Values.image.pullPolicy }}
        {{- if .Values.standalone.command }}
        command:
          {{- toYaml .Values.standalone.command | nindent 10 }}
        {{- else }}
        command: [/bin/sh, -ec]
        {{- end }}
        {{- if .Values.standalone.args }}
        args:
          {{- toYaml .Values.standalone.args | nindent 10 }}
        {{- else if not .Values.standalone.command }}
        args:
          - |-
            {{- include "relayflows.standaloneScript" . | nindent 12 }}
        {{- end }}
        env:
          - name: HOME
            value: {{ printf "%s/home" (trimSuffix "/" .Values.standalone.dataDir) | quote }}
          - name: RELAYFLOWS_DATA_DIR
            value: {{ .Values.standalone.dataDir | quote }}
          {{- if and (not .Values.standalone.resumeRunId) (not .Values.standalone.command) }}
          - name: RELAYFLOWS_FLOW_PATH
            value: {{ include "relayflows.standaloneFlowPath" . | quote }}
          {{- end }}
          {{- with .Values.standalone.input }}
          - name: RELAYFLOWS_INPUT
            value: {{ . | quote }}
          {{- end }}
          {{- with .Values.standalone.resumeRunId }}
          - name: RELAYFLOWS_RUN_ID
            value: {{ . | quote }}
          {{- end }}
          {{- if .Values.standalone.localAgent }}
          - name: RELAYFLOWS_AGENT_CAPACITY
            value: {{ .Values.standalone.agentCapacity | quote }}
          {{- end }}
          {{- if .Values.runtimeInstaller.enabled }}
          - name: PATH
            value: /opt/relayflows-runtime/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
          {{- end }}
          {{- with .Values.extraEnv }}
          {{- toYaml . | nindent 10 }}
          {{- end }}
          # Explicit env values override envFrom, including ESO-managed
          # Secrets. Keep the standalone path from opting into hosted
          # mirroring or Agent Relay telemetry through ambient environment.
          - name: FLOWS_CLOUD_MIRROR
            value: "0"
          - name: AGENT_RELAY_TELEMETRY_DISABLED
            value: "1"
        {{- with .Values.extraEnvFrom }}
        envFrom:
          {{- toYaml . | nindent 10 }}
        {{- end }}
        {{- with .Values.containerSecurityContext }}
        securityContext:
          {{- toYaml . | nindent 10 }}
        {{- end }}
        {{- with .Values.resources }}
        resources:
          {{- toYaml . | nindent 10 }}
        {{- end }}
        volumeMounts:
          - name: state
            mountPath: {{ .Values.standalone.dataDir | quote }}
          - name: tmp
            mountPath: /tmp
          {{- if .Values.runtimeInstaller.enabled }}
          - name: runtime
            mountPath: /opt/relayflows-runtime
          {{- end }}
          {{- if or .Values.standalone.flow.content .Values.standalone.flow.existingConfigMap }}
          - name: flow
            mountPath: /opt/relayflows/flow
            readOnly: true
          {{- end }}
          {{- with .Values.extraVolumeMounts }}
          {{- toYaml . | nindent 10 }}
          {{- end }}
    volumes:
      - name: state
        persistentVolumeClaim:
          claimName: {{ include "relayflows.pvcName" . }}
      - name: tmp
        emptyDir: {}
      {{- if .Values.runtimeInstaller.enabled }}
      - name: runtime
        emptyDir: {}
      {{- end }}
      {{- if or .Values.standalone.flow.content .Values.standalone.flow.existingConfigMap }}
      - name: flow
        configMap:
          name: {{ default (include "relayflows.flowConfigMapName" .) .Values.standalone.flow.existingConfigMap }}
      {{- end }}
      {{- with .Values.extraVolumes }}
      {{- toYaml . | nindent 6 }}
      {{- end }}
    {{- with .Values.nodeSelector }}
    nodeSelector:
      {{- toYaml . | nindent 6 }}
    {{- end }}
    {{- with .Values.affinity }}
    affinity:
      {{- toYaml . | nindent 6 }}
    {{- end }}
    {{- with .Values.tolerations }}
    tolerations:
      {{- toYaml . | nindent 6 }}
    {{- end }}
{{- end }}
