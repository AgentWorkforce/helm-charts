#!/usr/bin/env bash
# kind test: a FRESH CloudNativePG cluster (charts/96bulls initdb SQL) and an
# EXISTING one (created without the role, then searchWorkerRole.bootstrapJob)
# converge to the same session_directory_search_worker: exact attributes,
# exactly statement_timeout=2s, no membership (the migration owner hoop has no
# membership and no ADMIN). The Job is run twice (idempotent), and once against
# a drifted role (must fail, 55000, changing nothing).
#
# Real CNPG (deps/pins.txt) on kind. The only stand-in: the services image that
# carries the bootstrap file is a local busybox image with the vendored fixture
# at the same path (session_directory_search_worker.sql here); the rendered Job's
# initContainer image is pointed at it. Everything else is applied as rendered.
# Usage: ci/96bulls-search-worker-role/kind.sh
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
HERE="$ROOT/ci/96bulls-search-worker-role"
CLUSTER=${CLUSTER:-96bulls-role}
CTX="kind-$CLUSTER"
k() { kubectl --context "$CTX" "$@"; }
FIXTURE_IMAGE=96bulls-role-fixture:kind

kind get clusters | grep -qx "$CLUSTER" || kind create cluster --name "$CLUSTER" --wait 120s

work=$(mktemp -d "${TMPDIR:-/tmp}/role-fixture.XXXXXX")
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/app/supabase/bootstrap"
cp "$HERE/session_directory_search_worker.sql" "$work/app/supabase/bootstrap/"
printf 'FROM busybox:1.37\nCOPY app /app\nUSER 65534\n' > "$work/Dockerfile"
docker build -q -t "$FIXTURE_IMAGE" "$work" >/dev/null
kind load docker-image "$FIXTURE_IMAGE" --name "$CLUSTER"

# CloudNativePG operator from the pins.
helm repo add cnpg https://cloudnative-pg.github.io/charts >/dev/null 2>&1 || true
helm repo add minio https://charts.min.io/ >/dev/null 2>&1 || true
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts >/dev/null 2>&1 || true
helm repo update cnpg minio open-telemetry >/dev/null
read -r _ chart version values < <(grep '^cnpg-operator ' "$ROOT/deps/pins.txt")
k create namespace cnpg-system --dry-run=client -o yaml | k apply -f -
helm template cnpg "$chart" --version "$version" -f "$ROOT/deps/$values" --namespace cnpg-system --no-hooks --include-crds \
  | k -n cnpg-system apply --server-side --force-conflicts --field-manager=role-test -f -
k -n cnpg-system rollout status deploy --timeout=300s
helm dependency build "$ROOT/charts/96bulls" >/dev/null

render() { # namespace [helm args]
  local ns=$1; shift
  helm template bulls "$ROOT/charts/96bulls" --namespace "$ns" --no-hooks \
    -f "$ROOT/charts/96bulls/ci/search-worker-bootstrap-values.yaml" \
    --set hoopdb.cluster.storage.size=1Gi "$@"
}
cluster_of() { yq 'select(.kind == "Cluster")'; }
bootstrap_of() { yq 'select(.metadata.labels."app.kubernetes.io/component" == "search-worker-role-bootstrap")'; }

# FRESH: the chart's Cluster as is (initdb creates the role).
k create namespace fresh --dry-run=client -o yaml | k apply -f -
render fresh | cluster_of | k -n fresh apply --server-side -f -
# EXISTING: the same Cluster without the two role statements (a cluster from before them).
k create namespace existing --dry-run=client -o yaml | k apply -f -
render existing | cluster_of \
  | yq '.spec.bootstrap.initdb.postInitApplicationSQL |= map(select(test("session_directory_search_worker") | not))' \
  | k -n existing apply --server-side -f -
for ns in fresh existing; do k -n "$ns" wait cluster.postgresql.cnpg.io/hoopdb --for=condition=Ready --timeout=600s; done

psql_in() { # ns sql
  local pod
  pod=$(k -n "$1" get pods -l cnpg.io/cluster=hoopdb,cnpg.io/instanceRole=primary -o jsonpath='{.items[0].metadata.name}')
  k -n "$1" exec -i "$pod" -c postgres -- psql -X -At -d hoopdb -c "$2"
}
[ -z "$(psql_in existing "SELECT 1 FROM pg_roles WHERE rolname = 'session_directory_search_worker'")" ] || { echo "existing cluster already has the role"; exit 1; }

run_job() { # ns suffix -> exit status of the Job (0 complete, 1 failed)
  local ns=$1 suffix=$2 name
  render "$ns" | bootstrap_of \
    | yq "(select(.kind == \"Job\") | .metadata.name) += \"-$suffix\" | (select(.kind == \"Job\") | .spec.backoffLimit) = 0 | (select(.kind == \"Job\") | .spec.template.spec.initContainers[0].image) = \"$FIXTURE_IMAGE\"" \
    | k -n "$ns" apply --server-side --force-conflicts -f -
  name=$(render "$ns" | bootstrap_of | yq -r 'select(.kind == "Job") | .metadata.name')-$suffix
  k -n "$ns" wait "job/$name" --for=jsonpath='{.status.conditions[0].status}'=True --timeout=300s >/dev/null || true
  k -n "$ns" logs "job/$name" -c bootstrap || true
  [ "$(k -n "$ns" get "job/$name" -o jsonpath='{.status.succeeded}')" = "1" ]
}

run_job existing first || { echo "bootstrap Job failed on the existing cluster"; exit 1; }
run_job existing again || { echo "bootstrap Job is not idempotent"; exit 1; }

CHECK="
SELECT 'attrs', rolcanlogin, rolinherit, rolbypassrls, rolsuper, rolcreaterole, rolcreatedb, rolreplication FROM pg_roles WHERE rolname = 'session_directory_search_worker';
SELECT 'settings', s.setdatabase, s.setconfig FROM pg_db_role_setting s JOIN pg_roles r ON r.oid = s.setrole WHERE r.rolname = 'session_directory_search_worker';
SELECT 'members', count(*) FROM pg_auth_members m JOIN pg_roles g ON g.oid = m.roleid JOIN pg_roles u ON u.oid = m.member WHERE 'session_directory_search_worker' IN (g.rolname, u.rolname);
SELECT 'hoop', count(*) FROM pg_auth_members m JOIN pg_roles g ON g.oid = m.roleid JOIN pg_roles u ON u.oid = m.member WHERE g.rolname = 'session_directory_search_worker' AND u.rolname = 'hoop';
"
want=$'attrs|f|f|f|f|f|f|f\nsettings|0|{statement_timeout=2s}\nmembers|0\nhoop|0'
fresh=$(psql_in fresh "$CHECK"); existing=$(psql_in existing "$CHECK")
echo "fresh:";    echo "$fresh"
echo "existing:"; echo "$existing"
[ "$fresh" = "$want" ] || { echo "fresh cluster does not match the spec"; exit 1; }
[ "$existing" = "$fresh" ] || { echo "fresh and existing clusters do not converge"; exit 1; }

# The Job never alters a drifted role: it fails (55000) and changes nothing.
psql_in existing "ALTER ROLE session_directory_search_worker SET statement_timeout = '3s'" >/dev/null
if run_job existing drifted; then echo "bootstrap Job accepted a drifted role"; exit 1; fi
[ "$(psql_in existing "SELECT s.setconfig FROM pg_db_role_setting s JOIN pg_roles r ON r.oid = s.setrole WHERE r.rolname = 'session_directory_search_worker'")" = "{statement_timeout=3s}" ] \
  || { echo "the failed Job changed the role"; exit 1; }
echo "search-worker-role kind: OK (fresh and existing converge; idempotent; drift refused)"
