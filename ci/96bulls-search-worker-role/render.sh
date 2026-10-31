#!/usr/bin/env bash
# Rendered-chart assertions for the session directory search Worker role
# (charts/96bulls: hoopdb initdb SQL + searchWorkerRole.bootstrapJob). Offline.
# Usage: ci/96bulls-search-worker-role/render.sh
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
CHART="$ROOT/charts/96bulls"
fail=0
err() { echo "::error::$*"; fail=1; }
render() { helm template ci "$CHART" --namespace ci --no-hooks "$@"; }
base=(-f "$CHART/ci/default-values.yaml")
on=(-f "$CHART/ci/search-worker-bootstrap-values.yaml")

# 1. Fresh clusters: initdb creates the role with exactly the spec, as postgres.
sql=$(render "${base[@]}" | yq -r 'select(.kind == "Cluster") | .spec.bootstrap.initdb.postInitApplicationSQL[]')
grep -qxF "CREATE ROLE session_directory_search_worker NOLOGIN NOINHERIT NOBYPASSRLS NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION" <<<"$sql" || err "initdb: CREATE ROLE with the exact attributes is missing"
grep -qxF "ALTER ROLE session_directory_search_worker SET statement_timeout = '2s'" <<<"$sql" || err "initdb: statement_timeout = '2s' is missing"
# No grant of the role to anyone (the migration owner hoop gets no membership or ADMIN).
if grep -Ei "GRANT +session_directory_search_worker|session_directory_search_worker +TO" <<<"$sql"; then err "initdb: the role is granted to someone"; fi
# deps/cnpg-cluster-values.yaml carries the same two statements.
for line in "CREATE ROLE session_directory_search_worker NOLOGIN NOINHERIT NOBYPASSRLS NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION" "ALTER ROLE session_directory_search_worker SET statement_timeout = '2s'"; do
  yq -r '.cluster.initdb.postInitApplicationSQL[]' "$ROOT/deps/cnpg-cluster-values.yaml" | grep -qxF "$line" || err "deps/cnpg-cluster-values.yaml: missing: $line"
done

# 2. The existing-cluster Job is off by default: no Job, ServiceAccount or RBAC.
off=$(render "${base[@]}")
[ -z "$(yq -r 'select(.metadata.labels."app.kubernetes.io/component" == "search-worker-role-bootstrap") | .kind' <<<"$off")" ] || err "bootstrap objects rendered while disabled"

# 3. Enabled: a separate Job, its own ServiceAccount and a minimal Role.
out=$(render "${on[@]}")
pick() { yq "select(.kind == \"$1\" and .metadata.labels.\"app.kubernetes.io/component\" == \"search-worker-role-bootstrap\")" <<<"$out"; }
job=$(pick Job)
[ -n "$job" ] || err "enabled: no bootstrap Job"
sa=$(yq -r '.spec.template.spec.serviceAccountName' <<<"$job")
migrate_sa=$(yq -r 'select(.kind == "Job" and .metadata.labels."app.kubernetes.io/component" == "hoopdb-migrate") | .spec.template.spec.serviceAccountName' <<<"$out")
[ "$sa" != "$migrate_sa" ] || err "bootstrap Job shares the migrate Job's ServiceAccount ($sa)"
[ "$(yq -r '.metadata.name' <<<"$job")" != "$(yq -r 'select(.kind == "Job" and .metadata.labels."app.kubernetes.io/component" == "hoopdb-migrate") | .metadata.name' <<<"$out")" ] || err "bootstrap and migrate are the same Job"
rules=$(pick Role | yq -o=json -I=0 '.rules')
[ "$rules" = '[{"apiGroups":[""],"resources":["pods"],"verbs":["get","list"]},{"apiGroups":[""],"resources":["pods/exec"],"verbs":["create"]}]' ] || err "Role is not exactly pods get/list + pods/exec create: $rules"
[ -z "$(yq 'select(.kind == "ClusterRole" or .kind == "ClusterRoleBinding") | select(.metadata.labels."app.kubernetes.io/component" == "search-worker-role-bootstrap")' <<<"$out")" ] || err "cluster-scoped RBAC rendered"
# Images by digest; the SQL comes from the services image; superuser access stays off.
yq -r '.spec.template.spec.initContainers[0].image' <<<"$job" | grep -Eq '@sha256:[0-9a-f]{64}$' || err "sql image is not digest-pinned"
yq -r '.spec.template.spec.containers[0].image' <<<"$job" | grep -Eq '@sha256:[0-9a-f]{64}$' || err "kubectl image is not digest-pinned"
yq -r '.spec.template.spec.initContainers[0].command | join(" ")' <<<"$job" | grep -qF "/app/supabase/bootstrap/session_directory_search_worker.sql" || err "sql file path"
yq -r '.spec.template.spec.containers[0].args[0]' <<<"$job" | grep -qF 'kubectl exec -i "$pod" -c postgres -- psql -v ON_ERROR_STOP=1 -v VERBOSITY=verbose -X -d "${DATABASE}" -f - < /work/bootstrap.sql || rc=$?' || err "exec command"
yq -r '.spec.template.spec.containers[0].args[0]' <<<"$job" | grep -qxF 'exit "$rc"' || err "the container does not exit with psql's status"

# 3a. API token: none pod-wide; projected into the kubectl container only.
[ "$(yq -r '.spec.template.spec.automountServiceAccountToken' <<<"$job")" = "false" ] || err "pod-level automountServiceAccountToken is not false"
[ "$(yq -r '[.spec.template.spec.initContainers[].volumeMounts[] | select(.name == "kube-api" or (.mountPath | test("serviceaccount")))] | length' <<<"$job")" = 0 ] || err "the sql initContainer mounts an API token"
[ "$(yq -r '[.spec.template.spec.containers[].volumeMounts[] | select(.name == "kube-api" and .mountPath == "/var/run/secrets/kubernetes.io/serviceaccount")] | length' <<<"$job")" = 1 ] || err "the kubectl container does not mount the projected token"
[ "$(yq -r '.spec.template.spec.volumes[] | select(.name == "kube-api") | [.projected.sources[] | keys | .[0]] | join(",")' <<<"$job")" = "serviceAccountToken,configMap,downwardAPI" ] || err "kube-api is not a projected token volume"

# 3b. Pull auth: the bootstrap Job uses the workloads' pull Secret.
for args in "--set worker.imagePullSecrets[0].name=ghcr-pull" "--set shared.imagePullSecrets[0].name=unused"; do
  o=$(render "${on[@]}" $args)
  b=$(yq -o=json -I=0 'select(.kind == "Job" and .metadata.labels."app.kubernetes.io/component" == "search-worker-role-bootstrap") | .spec.template.spec.imagePullSecrets' <<<"$o")
  m=$(yq -o=json -I=0 'select(.kind == "Job" and .metadata.labels."app.kubernetes.io/component" == "hoopdb-migrate") | .spec.template.spec.imagePullSecrets' <<<"$o")
  [ "$b" = "$m" ] || err "bootstrap pull secrets ($b) differ from the migrate Job's ($m) with $args"
done
o=$(render "${on[@]}" --set 'worker.imagePullSecrets[0].name=ghcr-pull')
[ "$(yq -r 'select(.kind == "Job" and .metadata.labels."app.kubernetes.io/component" == "search-worker-role-bootstrap") | .spec.template.spec.imagePullSecrets[0].name' <<<"$o")" = "ghcr-pull" ] || err "bootstrap Job has no imagePullSecrets"

# 3c. Order: migrate's first init container waits for the role, on the HoopDb image.
mig=$(yq 'select(.kind == "Job" and .metadata.labels."app.kubernetes.io/component" == "hoopdb-migrate")' <<<"$out")
[ "$(yq -r '.spec.template.spec.initContainers[0].name' <<<"$mig")" = "wait-for-role" ] || err "migrate has no wait-for-role init container"
[ "$(yq -r '.spec.template.spec.initContainers[0].env[] | select(.name == "ROLE") | .value' <<<"$mig")" = "session_directory_search_worker" ] || err "wait-for-role waits for the wrong role"
[ "$(yq -r '.spec.template.spec.initContainers[0].image' <<<"$mig")" = "$(yq -r 'select(.kind == "Cluster") | .spec.imageName' <<<"$out")" ] || err "wait-for-role image differs from the HoopDb image"
[ "$(yq -r '.spec.template.spec.initContainers[0].env[] | select(.name == "HOOPDB_URL") | .valueFrom.secretKeyRef.name' <<<"$mig")" = "$(yq -r '.spec.template.spec.containers[0].env[] | select(.name == "HOOPDB_URL") | .valueFrom.secretKeyRef.name' <<<"$mig")" ] || err "wait-for-role reads a different HOOPDB_URL"
[ "$(yq -r 'select(.kind == "Cluster") | .spec.enableSuperuserAccess' <<<"$out")" = "false" ] || err "enableSuperuserAccess is not false"
[ -z "$(yq 'select(.metadata.annotations."helm.sh/hook")' <<<"$out")" ] || err "a Helm hook was rendered"

# 4. Misconfiguration fails the render.
expect_fail() { local msg=$1; shift; if o=$(render "$@" 2>&1); then err "rendered despite: $msg"; elif ! grep -qF "$msg" <<<"$o"; then err "wrong error for $msg: $o"; fi; }
expect_fail "sqlImage.repository and .digest are required" "${base[@]}" --set searchWorkerRole.bootstrapJob.enabled=true
expect_fail "sqlImage.digest must be sha256" "${on[@]}" --set searchWorkerRole.bootstrapJob.sqlImage.digest=latest
expect_fail "kubectlImage.digest must be sha256" "${on[@]}" --set searchWorkerRole.bootstrapJob.kubectlImage.digest=
expect_fail "needs worker.migrations.waitForRole.enabled" "${on[@]}" --set worker.migrations.waitForRole.enabled=false
expect_fail "waitForRole.image must be a full image reference" "${on[@]}" --set worker.migrations.waitForRole.image=postgres:17

# 5. values.yaml ends with exactly one newline.
[ "$(tail -c 2 "$CHART/values.yaml" | od -An -c | tr -d ' ')" != '\n\n' ] && [ "$(tail -c 1 "$CHART/values.yaml" | od -An -c | tr -d ' ')" = '\n' ] || err "charts/96bulls/values.yaml must end with a single newline"

[ $fail -eq 0 ] && echo "search-worker-role render: OK"
exit $fail
