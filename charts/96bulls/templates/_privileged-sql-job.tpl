{{- /*
A privileged CNPG SQL step: a bootstrap file from the pinned services image, run
as the CNPG superuser `postgres` by `kubectl exec` into the primary, IN the
HoopDb database. Its own ServiceAccount and a namespace Role that may only
find and exec into pods. No Helm hooks (Alchemy renders --no-hooks): migrate
waits for the roles (worker.migrations.waitForRole). Only the kubectl container
holds an API token; the sql init container runs the services image without one.
Args: c (the bootstrapJob values), root, component, suffix, what (log label),
psqlVars (list of "name=value", already validated).
*/ -}}
{{- define "96bulls.privilegedSqlJob" -}}
{{- $ := .root -}}
{{- $shared := $.Values.privilegedSql.sqlImage -}}
{{- $img := dict "repository" (.c.sqlImage.repository | default $shared.repository) "digest" (.c.sqlImage.digest | default $shared.digest) -}}
{{- $c := merge (dict "sqlImage" $img) (omit .c "sqlImage") -}}
{{- if not (and $c.sqlImage.repository $c.sqlImage.digest) }}{{ fail (printf "%s: sqlImage.repository and .digest are required (the Job's own or privilegedSql.sqlImage): the services image that carries the bootstrap file, by digest" .component) }}{{ end }}
{{- if not (regexMatch "^sha256:[0-9a-f]{64}$" $c.sqlImage.digest) }}{{ fail (printf "%s: sqlImage.digest must be sha256:<64 hex>" .component) }}{{ end }}
{{- if not (regexMatch "^sha256:[0-9a-f]{64}$" $c.kubectlImage.digest) }}{{ fail (printf "%s: kubectlImage.digest must be sha256:<64 hex>" .component) }}{{ end }}
{{- if not $.Values.worker.migrations.waitForRole.enabled }}{{ fail (printf "%s needs worker.migrations.waitForRole.enabled: it orders migrate after the bootstrap" .component) }}{{ end }}
{{- if not $.Values.hoopdb.enabled }}{{ fail (printf "%s runs in the in-cluster HoopDb (hoopdb.enabled); an external database's roles are operator steps" .component) }}{{ end }}
{{- $name := printf "%s-%s" $.Release.Name .suffix | trunc 50 | trimSuffix "-" }}
{{- $labels := dict "app.kubernetes.io/name" .component "app.kubernetes.io/instance" $.Release.Name "app.kubernetes.io/component" .component "app.kubernetes.io/part-of" "96bulls" }}
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: {{ $name }}
  namespace: {{ $.Release.Namespace | quote }}
  labels:
    {{- toYaml $labels | nindent 4 }}
automountServiceAccountToken: false
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: {{ $name }}
  namespace: {{ $.Release.Namespace | quote }}
  labels:
    {{- toYaml $labels | nindent 4 }}
rules:
  # Find the CNPG primary, then exec psql in it. Nothing else.
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["get", "list"]
  - apiGroups: [""]
    resources: ["pods/exec"]
    verbs: ["create"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: {{ $name }}
  namespace: {{ $.Release.Namespace | quote }}
  labels:
    {{- toYaml $labels | nindent 4 }}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: {{ $name }}
subjects:
  - kind: ServiceAccount
    name: {{ $name }}
    namespace: {{ $.Release.Namespace | quote }}
{{- $spec := include "96bulls.privilegedSqlJobSpec" (dict "c" $c "name" $name "labels" $labels "root" $ "what" .what "psqlVars" .psqlVars) }}
---
apiVersion: batch/v1
kind: Job
metadata:
  # Content-addressed, like hoopdb-migrate: a new image or spec runs it again.
  name: {{ printf "%s-%s" $name (sha256sum $spec | trunc 8) }}
  namespace: {{ $.Release.Namespace | quote }}
  labels:
    {{- toYaml $labels | nindent 4 }}
spec:
  {{- $spec | nindent 2 }}
{{- end }}

{{- define "96bulls.privilegedSqlJobSpec" -}}
{{- $c := .c -}}
backoffLimit: {{ $c.backoffLimit }}
activeDeadlineSeconds: {{ $c.activeDeadlineSeconds }}
template:
  metadata:
    labels:
      {{- toYaml .labels | nindent 6 }}
  spec:
    restartPolicy: Never
    serviceAccountName: {{ .name }}
    # No pod-wide token: only the kubectl container gets one (projected below).
    # The sql initContainer runs the services image without API credentials.
    automountServiceAccountToken: false
    {{- with .root.Values.worker.imagePullSecrets }}
    # The services image is private: the same pull Secret as the workloads.
    imagePullSecrets:
      {{- toYaml . | nindent 6 }}
    {{- end }}
    securityContext:
      runAsNonRoot: true
      runAsUser: 65534
      runAsGroup: 65534
      seccompProfile: { type: RuntimeDefault }
    initContainers:
      # The bootstrap file from the pinned services image (the source of truth).
      - name: sql
        image: "{{ $c.sqlImage.repository }}@{{ $c.sqlImage.digest }}"
        imagePullPolicy: IfNotPresent
        command: ["cp", "{{ $c.sqlPath }}", "/work/bootstrap.sql"]
        securityContext:
          allowPrivilegeEscalation: false
          readOnlyRootFilesystem: true
          capabilities: { drop: [ALL] }
        resources:
          {{- toYaml $c.resources | nindent 10 }}
        volumeMounts:
          - { name: work, mountPath: /work }
    containers:
      - name: bootstrap
        image: "{{ $c.kubectlImage.repository }}:{{ $c.kubectlImage.tag }}@{{ $c.kubectlImage.digest }}"
        imagePullPolicy: IfNotPresent
        env:
          - { name: HOME, value: /tmp }
          - { name: CLUSTER, value: {{ $c.cluster | quote }} }
          - { name: DATABASE, value: {{ $c.database | quote }} }
        command: ["/bin/sh", "-c"]
        args:
          - |
            set -eu
            pod=$(kubectl get pods -l "cnpg.io/cluster=${CLUSTER},cnpg.io/instanceRole=primary" -o jsonpath='{.items[0].metadata.name}')
            [ -n "$pod" ] || { echo "no CNPG primary for ${CLUSTER}" >&2; exit 1; }
            echo "bootstrap {{ .what }} via ${pod}"
            # VERBOSITY=verbose prints the SQLSTATE (42501, 55000) on failure;
            # psql exits 3 on a script error and kubectl exec passes it through.
            rc=0
            kubectl exec -i "$pod" -c postgres -- psql -v ON_ERROR_STOP=1 -v VERBOSITY=verbose {{- range .psqlVars }} -v {{ . | squote }}{{- end }} -X -d "${DATABASE}" -f - < /work/bootstrap.sql || rc=$?
            echo "bootstrap {{ .what }}: psql exit ${rc}"
            exit "$rc"
        securityContext:
          allowPrivilegeEscalation: false
          readOnlyRootFilesystem: true
          capabilities: { drop: [ALL] }
        resources:
          {{- toYaml $c.resources | nindent 10 }}
        volumeMounts:
          - { name: work, mountPath: /work, readOnly: true }
          - { name: tmp, mountPath: /tmp }
          # kubectl's in-cluster config path; this container only.
          - { name: kube-api, mountPath: /var/run/secrets/kubernetes.io/serviceaccount, readOnly: true }
    volumes:
      - { name: work, emptyDir: { sizeLimit: 1Mi } }
      - { name: tmp, emptyDir: { sizeLimit: 16Mi } }
      - name: kube-api
        projected:
          defaultMode: 0444
          sources:
            - serviceAccountToken: { path: token, expirationSeconds: 3600 }
            - configMap: { name: kube-root-ca.crt, items: [{ key: ca.crt, path: ca.crt }] }
            - downwardAPI: { items: [{ path: namespace, fieldRef: { fieldPath: metadata.namespace } }] }
{{- end }}
