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
yq -r '.spec.template.spec.containers[0].args[0]' <<<"$job" | grep -qF 'kubectl exec -i "$pod" -c postgres -- psql -v ON_ERROR_STOP=1 -X -d "${DATABASE}" -f -' || err "exec command"
[ "$(yq -r 'select(.kind == "Cluster") | .spec.enableSuperuserAccess' <<<"$out")" = "false" ] || err "enableSuperuserAccess is not false"
[ -z "$(yq 'select(.metadata.annotations."helm.sh/hook")' <<<"$out")" ] || err "a Helm hook was rendered"

# 4. Misconfiguration fails the render.
expect_fail() { local msg=$1; shift; if o=$(render "$@" 2>&1); then err "rendered despite: $msg"; elif ! grep -qF "$msg" <<<"$o"; then err "wrong error for $msg: $o"; fi; }
expect_fail "sqlImage.repository and .digest are required" "${base[@]}" --set searchWorkerRole.bootstrapJob.enabled=true
expect_fail "sqlImage.digest must be sha256" "${on[@]}" --set searchWorkerRole.bootstrapJob.sqlImage.digest=latest
expect_fail "kubectlImage.digest must be sha256" "${on[@]}" --set searchWorkerRole.bootstrapJob.kubectlImage.digest=

[ $fail -eq 0 ] && echo "search-worker-role render: OK"
exit $fail
