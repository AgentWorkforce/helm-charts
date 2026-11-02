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
{{- $migrations := .Values.migrations | default dict -}}
{{- $migrationHoopdb := get $migrations "hoopdb" | default dict -}}
{{- if not (or (eq $credentialsMode "secret") (eq $credentialsMode "podIdentity")) }}{{ fail "96bulls-worker: locker.credentials.mode must be secret or podIdentity" }}{{ end -}}
{{- if and (eq $credentialsMode "secret") (not .Values.existingSecret) }}{{ fail "96bulls-worker: existingSecret is required when locker.credentials.mode=secret" }}{{ end -}}
{{- if and (not .Values.hoopdb.existingSecret) (not .Values.existingSecret) }}{{ fail "96bulls-worker: hoopdb.existingSecret or existingSecret is required for HOOPDB_URL" }}{{ end -}}
{{- if ne (empty (get $migrationHoopdb "existingSecret")) (empty (get $migrationHoopdb "key")) }}{{ fail "96bulls-worker: migrations.hoopdb.existingSecret and key must be set together" }}{{ end -}}
{{- if and (eq $credentialsMode "secret") (not .Values.locker.endpoint) }}{{ fail "96bulls-worker: locker.endpoint is required when locker.credentials.mode=secret" }}{{ end -}}
{{- if not (include "96bulls-worker.orgId" .) }}{{ fail "96bulls-worker: tenant.orgId (or global.tenant.orgId) is required" }}{{ end -}}
{{- $idx := index .Values.components "hoopdb-indexer" -}}
{{- if and $idx.enabled (gt (int $idx.replicas) 1) }}{{ fail "96bulls-worker: components.hoopdb-indexer.replicas must be 1 (manifest reconcile is not leader-elected)" }}{{ end -}}
{{- /* Phase 2 role verify must run in migrate: with it off, readiness never passes
unless a separate mark_pass step runs, which this chart does not have. */ -}}
{{- $reserved := list "HOOPDB_ROLE_VERIFY" "HOOPDB_ROLE_BOOTSTRAP" "HOOPDB_DB_MODE" "HOOPDB_SUPABASE_SHIM" "HOOPDB_RUNTIME_ROLE" "HOOPDB_RUNTIME_ROLE_LOGIN" "HOOPDB_RUNTIME_WORKLOAD_ROLE" "HOOPDB_FUNCTION_BOUNDARY_MODE" "HOOPDB_FUNCTION_BOUNDARY_APPROVED" -}}
{{- range .Values.extraEnv }}{{ if has (.name | default "") $reserved }}{{ fail (printf "96bulls-worker: extraEnv must not set %s: it is a migrations.* value, rendered into migrate only" .name) }}{{ end }}{{ end -}}
{{- range $n, $c := .Values.components }}{{ range ($c.env | default list) }}{{ if has (.name | default "") $reserved }}{{ fail (printf "96bulls-worker: components.%s.env must not set %s: it is a migrations.* value, rendered into migrate only" $n .name) }}{{ end }}{{ end }}{{ end -}}
{{- if .Values.migrations.enabled }}{{ include "96bulls-worker.validateProfile" . }}{{ end -}}
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
Render Kubernetes EnvVar entries without letting YAML reinterpret a string such
as "6378" as a number. valueFrom is kept as structured YAML.
*/}}
{{- define "96bulls-worker.renderEnv" -}}
{{- range $entry := . }}
- name: {{ $entry.name | quote }}
{{- if hasKey $entry "value" }}
{{- if kindIs "invalid" $entry.value }}
  value: ""
{{- else }}
  value: {{ $entry.value | toString | quote }}
{{- end }}
{{- end }}
{{- with $entry.valueFrom }}
  valueFrom:
    {{- toYaml . | nindent 4 }}
{{- end }}
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
{{ include "96bulls-worker.hoopdbUrlEnv" (dict "root" .context "migrate" (eq .service "hoopdb-migrate")) }}
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
{{ include "96bulls-worker.renderEnv" . }}
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

{{/*
HOOPDB_URL from the HoopDb Secret (context: the chart root).
*/}}
{{- define "96bulls-worker.hoopdbUrlEnv" -}}
{{- $v := .root.Values -}}
{{- $secret := $v.hoopdb.existingSecret | default $v.existingSecret -}}
{{- $key := $v.hoopdb.key | default $v.secretKeys.hoopdbUrl -}}
{{- if .migrate -}}
{{- /* migrate and its wait-for-role: the migration-owner URL when set
(migrations.hoopdb). wait-for-role checks current_user's function default, so
it must connect as the same owner as the migrator. */ -}}
{{- $migrations := $v.migrations | default dict -}}
{{- $migrationHoopdb := get $migrations "hoopdb" | default dict -}}
{{- $secret = get $migrationHoopdb "existingSecret" | default $secret -}}
{{- $key = get $migrationHoopdb "key" | default $key -}}
{{- end -}}
- name: HOOPDB_URL
  valueFrom:
    secretKeyRef:
      name: {{ $secret | quote }}
      key: {{ $key | quote }}
{{- end }}

{{/*
The migrator's database profile: the same refusals as 96BullSessions
migrationProfile() (#99), at render time, plus the chart's own: wait-for-role
is refused in supabase mode (no shim, no bootstrap, no in-cluster role steps).
Role names follow the migrator's pattern exactly.
*/}}
{{- define "96bulls-worker.validateProfile" -}}
{{- $m := .Values.migrations -}}
{{- $ident := "^[A-Za-z_][A-Za-z0-9_$-]{0,62}$" -}}
{{- if not (has $m.databaseMode (list "local" "selfhosted" "cloudsql" "supabase")) }}{{ fail "96bulls-worker: migrations.databaseMode must be local, selfhosted, cloudsql or supabase (HOOPDB_DB_MODE has no default)" }}{{ end -}}
{{- if not (or (kindIs "invalid" $m.roleBootstrap) (kindIs "bool" $m.roleBootstrap)) }}{{ fail "96bulls-worker: migrations.roleBootstrap must be true or false" }}{{ end -}}
{{- if not (or (kindIs "invalid" $m.supabaseShim) (kindIs "bool" $m.supabaseShim)) }}{{ fail "96bulls-worker: migrations.supabaseShim must be true or false" }}{{ end -}}
{{- if not (or (kindIs "invalid" $m.runtimeRoleLogin) (kindIs "bool" $m.runtimeRoleLogin)) }}{{ fail "96bulls-worker: migrations.runtimeRoleLogin must be true or false" }}{{ end -}}
{{- if eq $m.databaseMode "supabase" }}
{{- if eq $m.supabaseShim true }}{{ fail "96bulls-worker: migrations.supabaseShim must not be true in supabase mode (the plain-Postgres role shim never runs there)" }}{{ end -}}
{{- if $m.waitForRole.enabled }}{{ fail "96bulls-worker: migrations.waitForRole must be disabled in supabase mode (the roles are operator steps; the migrator verifies them)" }}{{ end -}}
{{- if eq $m.roleBootstrap true }}{{ fail "96bulls-worker: migrations.roleBootstrap must not be true in supabase mode (the privileged role bootstrap never runs from the migrator there)" }}{{ end -}}
{{- else if kindIs "invalid" $m.supabaseShim }}{{ fail (printf "96bulls-worker: migrations.supabaseShim must be set (true or false) in %s mode" $m.databaseMode) }}{{ end -}}
{{- if not (regexMatch $ident ($m.runtimeRole | default "")) }}{{ fail "96bulls-worker: migrations.runtimeRole is required: the role the services connect as (HOOPDB_RUNTIME_ROLE)" }}{{ end -}}
{{- if eq $m.runtimeRole "session_directory_search_worker" }}{{ fail "96bulls-worker: migrations.runtimeRole must not be the search Worker role" }}{{ end -}}
{{- if and (ne $m.databaseMode "local") (kindIs "invalid" $m.runtimeRoleLogin) }}{{ fail (printf "96bulls-worker: migrations.runtimeRoleLogin must be set (true or false) in %s mode" $m.databaseMode) }}{{ end -}}
{{- if and $m.runtimeWorkloadRole (not (regexMatch $ident $m.runtimeWorkloadRole)) }}{{ fail "96bulls-worker: migrations.runtimeWorkloadRole must be a role name" }}{{ end -}}
{{- if hasKey $m "functionBoundaryApproved" }}{{ fail "96bulls-worker: migrations.functionBoundaryApproved was renamed functionBoundaryMode (HOOPDB_FUNCTION_BOUNDARY_MODE); remove it" }}{{ end -}}
{{- if and (eq ($m.functionBoundaryMode | default "") "event-trigger") (ne $m.databaseMode "supabase") }}{{ fail (printf "96bulls-worker: migrations.functionBoundaryMode=event-trigger is supported only in supabase mode, not %s (selfhosted and cloudsql use global-default-revoke)" $m.databaseMode) }}{{ end -}}
{{- if and $m.functionBoundaryMode (not (has $m.functionBoundaryMode (list "global-default-revoke" "event-trigger"))) }}{{ fail "96bulls-worker: migrations.functionBoundaryMode must be global-default-revoke or (supabase only) event-trigger" }}{{ end -}}
{{- if and (has $m.databaseMode (list "selfhosted" "cloudsql")) (not $m.functionBoundaryMode) }}{{ fail (printf "96bulls-worker: migrations.functionBoundaryMode is required in %s mode (global-default-revoke; the migrator's function-boundary gate refuses without it)" $m.databaseMode) }}{{ end -}}
{{- if and $m.waitForRole.functionDefault (not $m.waitForRole.enabled) }}{{ fail "96bulls-worker: migrations.waitForRole.functionDefault needs migrations.waitForRole.enabled" }}{{ end -}}
{{- if and $m.waitForRole.functionDefault (ne ($m.functionBoundaryMode | default "") "global-default-revoke") }}{{ fail "96bulls-worker: migrations.waitForRole.functionDefault needs functionBoundaryMode global-default-revoke" }}{{ end -}}
{{- end }}

{{/*
The migrate container's profile env, each name exactly once (context: migrations).
*/}}
{{- define "96bulls-worker.profileEnv" -}}
- name: HOOPDB_DB_MODE
  value: {{ .databaseMode | quote }}
- name: HOOPDB_SUPABASE_SHIM
  value: {{ ternary "true" "false" (eq .supabaseShim true) | quote }}
- name: HOOPDB_RUNTIME_ROLE
  value: {{ .runtimeRole | quote }}
{{- if not (kindIs "invalid" .runtimeRoleLogin) }}
- name: HOOPDB_RUNTIME_ROLE_LOGIN
  value: {{ ternary "true" "false" .runtimeRoleLogin | quote }}
{{- end }}
{{- with .runtimeWorkloadRole }}
- name: HOOPDB_RUNTIME_WORKLOAD_ROLE
  value: {{ . | quote }}
{{- end }}
{{- if not (kindIs "invalid" .roleBootstrap) }}
- name: HOOPDB_ROLE_BOOTSTRAP
  value: {{ ternary "true" "false" .roleBootstrap | quote }}
{{- end }}
{{- with .functionBoundaryMode }}
- name: HOOPDB_FUNCTION_BOUNDARY_MODE
  value: {{ . | quote }}
{{- end }}
{{- end }}
