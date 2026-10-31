#!/usr/bin/env bash
# kind test: a FRESH CloudNativePG cluster (charts/96bulls initdb SQL) and an
# EXISTING one (created without the role, then searchWorkerRole.bootstrapJob)
# converge to the same session_directory_search_worker: exact attributes,
# exactly statement_timeout=2s, no membership (the migration owner hoop has no
# membership and no ADMIN). The Job is run twice (idempotent), and once against
# a drifted role (must fail, 55000, changing nothing).
# Then, with SERVICES_IMAGE, the full release: see "Full flow" below.
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

# On any failure: Job/pod state, events, init container and Job logs, and
# readiness probe failures for every namespace this test uses. No Secret
# objects and no env dumps.
diagnose() {
  local rc=$? ns p
  [ "$rc" -eq 0 ] && return
  echo "::group::diagnostics (exit $rc)"
  for ns in fresh existing flow-existing flow-drifted; do
    k get namespace "$ns" >/dev/null 2>&1 || continue
    echo "=== $ns"
    k -n "$ns" get cluster.postgresql.cnpg.io,jobs,pods,deploy -o wide 2>&1 || true
    k -n "$ns" get events --sort-by=.lastTimestamp 2>&1 | tail -40 || true
    for p in $(k -n "$ns" get pods -o name 2>/dev/null); do
      echo "--- $p"
      k -n "$ns" get "$p" -o jsonpath='{range .status.initContainerStatuses[*]}init {.name} ready={.ready} {.state}{"\n"}{end}{range .status.containerStatuses[*]}ctr {.name} ready={.ready} {.state}{"\n"}{end}' 2>&1 || true
      k -n "$ns" logs "$p" --all-containers --prefix --tail=40 2>&1 || true
      k -n "$ns" get events --field-selector "involvedObject.name=${p#pod/},reason=Unhealthy" -o jsonpath='{range .items[*]}{.message}{"\n"}{end}' 2>&1 | tail -3 || true
    done
  done
  echo "::endgroup::"
}

kind get clusters | grep -qx "$CLUSTER" || kind create cluster --name "$CLUSTER" --wait 120s

work=$(mktemp -d "${TMPDIR:-/tmp}/role-fixture.XXXXXX")
trap 'diagnose; rm -rf "$work"' EXIT
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

JOB_LOG= JOB_EXIT=
run_job() { # ns suffix -> 0 if the Job completed; sets JOB_LOG and JOB_EXIT (the bootstrap container's exit code)
  local ns=$1 suffix=$2 name
  render "$ns" | bootstrap_of \
    | yq "(select(.kind == \"Job\") | .metadata.name) += \"-$suffix\" | (select(.kind == \"Job\") | .spec.backoffLimit) = 0 | (select(.kind == \"Job\") | .spec.template.spec.initContainers[0].image) = \"$FIXTURE_IMAGE\"" \
    | k -n "$ns" apply --server-side --force-conflicts -f -
  name=$(render "$ns" | bootstrap_of | yq -r 'select(.kind == "Job") | .metadata.name')-$suffix
  k -n "$ns" wait "job/$name" --for=jsonpath='{.status.conditions[0].status}'=True --timeout=300s >/dev/null || true
  JOB_LOG=$(k -n "$ns" logs "job/$name" -c bootstrap 2>&1 || true)
  echo "$JOB_LOG"
  JOB_EXIT=$(k -n "$ns" get pods -l "batch.kubernetes.io/job-name=$name" -o jsonpath='{.items[0].status.containerStatuses[?(@.name=="bootstrap")].state.terminated.exitCode}')
  [ "$(k -n "$ns" get "job/$name" -o jsonpath='{.status.succeeded}')" = "1" ]
}
# The container ran the file (not an image pull or exec failure), psql reported
# SQLSTATE $1, and the container exited with psql's script-error status 3.
assert_sqlstate() { # sqlstate where
  grep -qF "bootstrap session_directory_search_worker via " <<<"$JOB_LOG" || { echo "$2: the bootstrap container never reached psql"; exit 1; }
  grep -qE "^(psql:[^ ]* )?ERROR:  $1: bootstrap session_directory_search_worker" <<<"$JOB_LOG" || { echo "$2: no SQLSTATE $1 from the bootstrap file"; exit 1; }
  grep -qxF "bootstrap session_directory_search_worker: psql exit 3" <<<"$JOB_LOG" || { echo "$2: psql did not exit 3"; exit 1; }
  [ "$JOB_EXIT" = 3 ] || { echo "$2: bootstrap container exit code is '$JOB_EXIT', want 3"; exit 1; }
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
assert_sqlstate 55000 "drifted role"
[ "$(psql_in existing "SELECT s.setconfig FROM pg_db_role_setting s JOIN pg_roles r ON r.oid = s.setrole WHERE r.rolname = 'session_directory_search_worker'")" = "{statement_timeout=3s}" ] \
  || { echo "the failed Job changed the role"; exit 1; }
echo "search-worker-role kind: role OK (fresh and existing converge; idempotent; drift refused with 55000, exit 3)"

# ---------------------------------------------------------------------------
# Full flow: the whole umbrella release, as Alchemy applies it, on the real
# services image (SERVICES_IMAGE, built from 96BullSessions with the bootstrap
# and verify files): bootstrap -> migrate (wait-for-role, phase 1 verify,
# migrations, phase 2 verify) -> workloads ready. The services image is
# private; without SERVICES_IMAGE this part does not run and says so.
# ---------------------------------------------------------------------------
if [ -z "${SERVICES_IMAGE:-}" ]; then
  msg="search-worker-role kind: FULL FLOW NOT RUN (set SERVICES_IMAGE to a local services image; the published one is private)"
  if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::warning::$msg"; else echo "$msg"; fi
  exit 0
fi
kind load docker-image "$SERVICES_IMAGE" --name "$CLUSTER"
k delete namespace fresh existing --wait=false >/dev/null 2>&1 || true
IMG_REPO=${SERVICES_IMAGE%:*} IMG_TAG=${SERVICES_IMAGE##*:}
full_render() { # ns
  helm template bulls "$ROOT/charts/96bulls" --namespace "$1" --no-hooks \
    -f "$ROOT/charts/96bulls/ci/kind-values.yaml" \
    --set global.imageRegistry= --set hoopdb.cluster.storage.size=1Gi --set otel.enabled=false --set global.otel.endpoint= \
    --set "worker.image.repository=$IMG_REPO" --set "worker.image.tag=$IMG_TAG" --set worker.image.digest= \
    --set "alleyoop.image.repository=$IMG_REPO" --set "alleyoop.image.tag=$IMG_TAG" --set alleyoop.image.digest= \
    --set searchWorkerRole.bootstrapJob.enabled=true \
    --set "searchWorkerRole.bootstrapJob.sqlImage.repository=$IMG_REPO" \
    --set "searchWorkerRole.bootstrapJob.sqlImage.digest=sha256:$(printf '%064d' 1)" \
    | yq "(select(.metadata.labels.\"app.kubernetes.io/component\" == \"search-worker-role-bootstrap\" and .kind == \"Job\") | .spec.template.spec.initContainers[0].image) = \"$SERVICES_IMAGE\" | (select(.metadata.labels.\"app.kubernetes.io/component\" == \"search-worker-role-bootstrap\" and .kind == \"Job\") | .spec.template.spec.initContainers[0].imagePullPolicy) = \"Never\""
  # The only change to the render: a local image cannot be referenced by
  # registry digest, so the bootstrap Job's sql image points at the same tag.
}
is_boot_job='select(.kind == "Job" and .metadata.labels."app.kubernetes.io/component" == "search-worker-role-bootstrap")'
not_boot_job='select((.kind == "Job" and .metadata.labels."app.kubernetes.io/component" == "search-worker-role-bootstrap") | not)'
prepare_ns() { # ns with_role(fresh|absent|drifted)
  local ns=$1
  k create namespace "$ns" --dry-run=client -o yaml | k apply -f - >/dev/null
  k -n "$ns" create secret generic 96bulls-locker --from-literal=rootUser=locker --from-literal=rootPassword=locker-kind-only \
    --from-literal=SUMMARY_MASTER_KEYS="kind1:$(openssl rand -hex 32)" --from-literal=JWKS_JSON='{"keys":[]}' \
    --dry-run=client -o yaml | k apply -f - >/dev/null
  if [ "$2" = fresh ]; then full_render "$ns" | cluster_of | k -n "$ns" apply --server-side -f - >/dev/null
  else full_render "$ns" | cluster_of \
    | yq '.spec.bootstrap.initdb.postInitApplicationSQL |= map(select(test("session_directory_search_worker") | not))' \
    | k -n "$ns" apply --server-side -f - >/dev/null; fi
  k -n "$ns" wait cluster.postgresql.cnpg.io/hoopdb --for=condition=Ready --timeout=600s >/dev/null
  if [ "$2" = drifted ]; then
    psql_in "$ns" "CREATE ROLE session_directory_search_worker NOLOGIN NOINHERIT NOBYPASSRLS NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION" >/dev/null
    psql_in "$ns" "ALTER ROLE session_directory_search_worker SET statement_timeout = '3s'" >/dev/null
  fi
}
app_ready() { # ns -> total readyReplicas over the four app Deployments
  k -n "$1" get deploy -l 'app.kubernetes.io/name in (worker,alleyoop)' -o json | jq '[.items[].status.readyReplicas // 0] | add // 0'
}
app_count() { k -n "$1" get deploy -l 'app.kubernetes.io/name in (worker,alleyoop)' -o name | wc -l; }
job_name() { k -n "$1" get jobs -l "app.kubernetes.io/component=$2" -o jsonpath='{.items[0].metadata.name}'; }
pod_of() { k -n "$1" get pods -l "batch.kubernetes.io/job-name=$2" -o jsonpath='{.items[0].metadata.name}'; }
cstat() { # ns pod jsonpath-under-status
  k -n "$1" get pod "$2" -o jsonpath="{.status.$3}"
}
epoch() { date -d "$1" +%s; }

# 1. EXISTING cluster without the role. Apply everything but the bootstrap
# Job and hold it back for a window: migrate must wait, workloads stay unready.
prepare_ns flow-existing absent
[ -z "$(psql_in flow-existing "SELECT 1 FROM pg_roles WHERE rolname = 'session_directory_search_worker'")" ] || { echo "flow-existing: role present before bootstrap"; exit 1; }
full_render flow-existing | yq "$not_boot_job" | k -n flow-existing apply --server-side --force-conflicts --field-manager=role-test -f - >/dev/null
[ "$(app_count flow-existing)" = 4 ] || { echo "flow-existing: expected 4 app Deployments"; exit 1; }
mj=$(job_name flow-existing hoopdb-migrate)
k -n flow-existing wait --for=condition=complete job -l app.kubernetes.io/component=locker-init --timeout=300s >/dev/null
for i in $(seq 1 12); do  # 120s
  sleep 10
  [ "$(k -n flow-existing get "job/$mj" -o jsonpath='{.status.succeeded}')" != 1 ] || { echo "flow-existing: migrate completed before the bootstrap ran"; exit 1; }
  [ "$(app_ready flow-existing)" = 0 ] || { echo "flow-existing: a workload became ready before bootstrap+migrate"; exit 1; }
done
mp=$(pod_of flow-existing "$mj")
[ -z "$(cstat flow-existing "$mp" 'containerStatuses[?(@.name=="migrate")].state.running')$(cstat flow-existing "$mp" 'containerStatuses[?(@.name=="migrate")].state.terminated')" ] \
  || { echo "flow-existing: the migrate container started while the role was absent"; exit 1; }
k -n flow-existing logs "$mp" -c wait-for-role | grep -qF "wait-for-role: session_directory_search_worker not present yet" || { echo "flow-existing: wait-for-role did not wait"; exit 1; }
echo "flow-existing: held 120s without the bootstrap: migrate waiting in wait-for-role, 0 app pods ready"

# 2. Now the bootstrap Job. It runs; migrate follows; workloads become ready.
full_render flow-existing | yq "$is_boot_job" | k -n flow-existing apply --server-side --force-conflicts --field-manager=role-test -f - >/dev/null
bj=$(job_name flow-existing search-worker-role-bootstrap)
k -n flow-existing wait --for=condition=complete "job/$bj" --timeout=300s >/dev/null || { k -n flow-existing logs "job/$bj" -c bootstrap; echo "flow-existing: bootstrap failed"; exit 1; }
k -n flow-existing wait --for=condition=complete "job/$mj" --timeout=900s >/dev/null || { k -n flow-existing logs "job/$mj" --all-containers; echo "flow-existing: migrate failed"; exit 1; }
k -n flow-existing rollout status deploy -l 'app.kubernetes.io/name in (worker,alleyoop)' --timeout=600s >/dev/null
[ "$(app_ready flow-existing)" -ge 4 ] || { echo "flow-existing: workloads not ready after bootstrap+migrate"; exit 1; }
bp=$(pod_of flow-existing "$bj"); mp=$(pod_of flow-existing "$mj")
b_start=$(epoch "$(cstat flow-existing "$bp" 'containerStatuses[?(@.name=="bootstrap")].state.terminated.startedAt')")
w_end=$(epoch "$(cstat flow-existing "$mp" 'initContainerStatuses[?(@.name=="wait-for-role")].state.terminated.finishedAt')")
m_start=$(epoch "$(cstat flow-existing "$mp" 'containerStatuses[?(@.name=="migrate")].state.terminated.startedAt')")
[ "$w_end" -ge "$b_start" ] && [ "$m_start" -ge "$b_start" ] || { echo "flow-existing: order violated (bootstrap start $b_start, wait end $w_end, migrate start $m_start)"; exit 1; }
mlog=$(k -n flow-existing logs "$mp" -c migrate)
for step in bootstrap verify; do
  grep '"message":"role check passed"' <<<"$mlog" | grep -qF "\"reason\":\"$step:session_directory_search_worker\"" || { echo "flow-existing: migrate did not pass $step:session_directory_search_worker"; exit 1; }
done
[ "$(psql_in flow-existing "$CHECK")" = "$want" ] || { echo "flow-existing: role does not match the spec after the full flow"; exit 1; }
echo "flow-existing: bootstrap started $b_start <= wait-for-role released $w_end <= migrate started $m_start; phase 1 + phase 2 passed; $(app_ready flow-existing) app pods ready"
k delete namespace flow-existing --wait=false >/dev/null

# 3. DRIFTED: a role that differs from the spec, then the whole release at
# once. Both Jobs fail with 55000, the role is unchanged, nothing becomes ready.
prepare_ns flow-drifted drifted
full_render flow-drifted \
  | yq '(select(.kind == "Job" and (.metadata.labels."app.kubernetes.io/component" == "search-worker-role-bootstrap" or .metadata.labels."app.kubernetes.io/component" == "hoopdb-migrate")) | .spec.backoffLimit) = 0' \
  | k -n flow-drifted apply --server-side --force-conflicts --field-manager=role-test -f - >/dev/null
bj=$(job_name flow-drifted search-worker-role-bootstrap); mj=$(job_name flow-drifted hoopdb-migrate)
k -n flow-drifted wait --for=condition=failed "job/$bj" --timeout=300s >/dev/null || { echo "flow-drifted: bootstrap did not fail"; exit 1; }
JOB_LOG=$(k -n flow-drifted logs "job/$bj" -c bootstrap 2>&1); echo "$JOB_LOG"
JOB_EXIT=$(cstat flow-drifted "$(pod_of flow-drifted "$bj")" 'containerStatuses[?(@.name=="bootstrap")].state.terminated.exitCode')
assert_sqlstate 55000 "flow-drifted (full flow)"
k -n flow-drifted wait --for=condition=failed "job/$mj" --timeout=600s >/dev/null || { echo "flow-drifted: migrate did not fail"; exit 1; }
mlog=$(k -n flow-drifted logs "$(pod_of flow-drifted "$mj")" -c migrate 2>&1)
grep '"message":"role check failed"' <<<"$mlog" | grep -F '"reason":"bootstrap:session_directory_search_worker"' | grep -qF '"error_code":"55000"' \
  || { echo "$mlog" | tail -5; echo "flow-drifted: migrate did not refuse the role with 55000"; exit 1; }
for i in $(seq 1 6); do sleep 10; [ "$(app_ready flow-drifted)" = 0 ] || { echo "flow-drifted: a workload became ready"; exit 1; }; done
[ "$(psql_in flow-drifted "SELECT s.setconfig FROM pg_db_role_setting s JOIN pg_roles r ON r.oid = s.setrole WHERE r.rolname = 'session_directory_search_worker'")" = "{statement_timeout=3s}" ] || { echo "flow-drifted: the role was changed"; exit 1; }
echo "flow-drifted: bootstrap 55000 (exit 3), migrate 55000, role unchanged, 0 app pods ready after 60s"
k delete namespace flow-drifted --wait=false >/dev/null
echo "search-worker-role kind: FULL FLOW OK"
