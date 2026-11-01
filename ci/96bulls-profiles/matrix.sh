#!/usr/bin/env bash
# Bootstrap/render matrix for charts/96bulls. It covers every shipped profile
# (charts/96bulls/profiles/*.yaml) and every CI values file
# (charts/96bulls/ci/*-values.yaml), including the AWS and GCP stack shapes.
# Each is rendered the way Alchemy installs (helm template --no-hooks) and
# checked against the 96BullSessions #99 migration contract. The checks cover:
# - the app workloads and the migrate Job;
# - the migrator profile env, exactly once and in migrate only;
# - HoopDb and Locker;
# - the role/boundary bootstrap path. A fresh in-cluster cluster gets initdb
#   plus the runtime-role and function-default Jobs. An existing cluster also
#   gets the search Worker Job. An external selfhosted database gets
#   wait-for-role only. Supabase gets nothing in-cluster.
# A profile without a row fails the matrix. So do the mode combinations the
# migrator or the chart must refuse.
#
#   ci/96bulls-profiles/matrix.sh static   offline: lint + render assertions
#   ci/96bulls-profiles/matrix.sh dryrun   also server-side dry-run apply (needs
#                                          a cluster with the CNPG CRDs and ns ci)
# Run `helm dependency build charts/96bulls` first.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
CHART="$ROOT/charts/96bulls"
mode=${1:-static}
case $mode in static|dryrun) ;; *) echo "usage: $0 static|dryrun" >&2; exit 2 ;; esac
fail=0
err() { echo "::error::$*"; fail=1; }
render() { helm template ci "$CHART" --namespace ci --no-hooks "$@"; }

# The inputs a shipped profile leaves to the operator (CI values files carry
# their own).
REQUIRED=(--set global.tenant.orgId=org_ci --set alleyoop.auth.jwksUrl=https://relayauth.example.com/.well-known/jwks.json)
RUNTIME=(--set worker.migrations.runtimeRole=bulls96_runtime --set worker.migrations.runtimeRoleLogin=true)

# file (relative to charts/96bulls) | HoopDb Cluster | Locker | databaseMode | shape
#   fresh     in-cluster, new cluster: initdb creates the search Worker role; the
#             runtime-role and function-default Jobs; wait for roles + function default
#   existing  in-cluster, existing cluster: fresh plus the search Worker Job
#   external  external plain Postgres: no SQL Jobs; wait for the roles only
#   supabase  external Supabase: no SQL Jobs, no wait-for-role, no shim
MATRIX=(
  "profiles/selfhost-postgres.yaml|yes|yes|selfhosted|fresh"
  "profiles/migration.yaml|yes|yes|selfhosted|existing"
  "profiles/external-supabase.yaml|no|yes|supabase|supabase"
  "profiles/external-selfhosted.yaml|no|yes|selfhosted|external"
  "ci/default-values.yaml|yes|yes|selfhosted|fresh"
  "ci/kind-values.yaml|yes|yes|selfhosted|fresh"
  "ci/search-worker-bootstrap-values.yaml|yes|yes|selfhosted|existing"
  "ci/aws-cnpg-values.yaml|yes|no|selfhosted|fresh"
  "ci/pod-identity-values.yaml|no|no|supabase|supabase"
  "ci/gcp-cloudsql-values.yaml|no|no|cloudsql|external"
)

# Every profile on disk has a row (a new profile cannot skip the matrix).
for f in "$CHART"/profiles/*.yaml "$CHART"/ci/*-values.yaml; do
  rel=${f#"$CHART"/}
  printf '%s\n' "${MATRIX[@]}" | cut -d'|' -f1 | grep -qxF "$rel" || err "$rel: no row in the profile matrix"
done

# Services image pins. The in-cluster CNPG profiles and the AWS proof values
# pin the image built from 96BullSessions main b47c1e6 (#99 + #106): GHCR
# (publish-image run 41333160108) and ECR (publish-image-ecr run 41333164245). The workloads and
# the privileged SQL Jobs use the same image, and no Job overrides it. The
# external-selfhosted profile pins nothing (the operator's own Postgres). The
# Supabase profile pins the GHCR image too, but stays fail-closed (hold, no
# boundary mode).
GHCR="ghcr.io/agentworkforce/96bulls-services@sha256:e48d62dacc6dd6c0d0f912656693bb4a937c1f0d14562afa273601ea1ba0463a"
ECR="500268966557.dkr.ecr.us-west-2.amazonaws.com/96bulls-services@sha256:5fb1cc209c9f0398ee0c9cf3cf050335f2388241df1b307538e915ca76f3c698"
pins_of() { yq -r '[.worker.image.tag, .worker.image.digest, .alleyoop.image.tag, .alleyoop.image.digest, .privilegedSql.sqlImage.digest, .searchWorkerRole.bootstrapJob.sqlImage.digest, .runtimeRole.bootstrapJob.sqlImage.digest, .functionDefaultRevoke.bootstrapJob.sqlImage.digest] | map(select(. != null and . != "")) | join(",")' "$1"; }
f="$CHART/profiles/external-selfhosted.yaml"
[ -z "$(pins_of "$f")" ] || err "profiles/external-selfhosted.yaml: pins a services image ($(pins_of "$f"))"
# Rendered image refs of every services container (workloads, migrate, the SQL Jobs' sql copy).
services_refs() {
  render "$@" | yq -r 'select(.kind == "Deployment" or .kind == "Job") | .spec.template.spec | ((.initContainers // []) + .containers)[] | select(.image | test("96bulls-services")) | .image' | grep -v '^---$' | sort -u
}
for pair in "profiles/selfhost-postgres.yaml|$GHCR" "profiles/migration.yaml|$GHCR" "profiles/external-supabase.yaml|$GHCR" "ci/aws-cnpg-values.yaml|$ECR"; do
  rel=${pair%%|*} want=${pair#*|}
  extra=(); [[ $rel == profiles/* ]] && extra=("${REQUIRED[@]}")
  [[ $rel == profiles/external-supabase.yaml ]] && extra+=(--set supabaseActivation.hold=false)
  got=$(services_refs -f "$CHART/$rel" "${extra[@]}" | tr '\n' ' ' | sed 's/ $//')
  [ "$got" = "$want" ] || err "$rel: services images are [$got], want exactly [$want]"
done

ROLE_SQL="CREATE ROLE session_directory_search_worker NOLOGIN NOINHERIT NOBYPASSRLS NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION"
PROFILE_ENV="HOOPDB_DB_MODE HOOPDB_SUPABASE_SHIM HOOPDB_ROLE_BOOTSTRAP HOOPDB_RUNTIME_ROLE HOOPDB_RUNTIME_ROLE_LOGIN HOOPDB_RUNTIME_WORKLOAD_ROLE HOOPDB_FUNCTION_BOUNDARY_MODE"
count() { yq "select($1)" <<<"$out" | yq -N 'select(. != null) | .kind' | grep -c . || true; }
has() { [ "$(count "$1")" -ge 1 ]; }
none() { [ "$(count "$1")" -eq 0 ]; }
comp() { echo ".metadata.labels.\"app.kubernetes.io/component\" == \"$1\""; }
# name=value pairs of the migrate container's profile env, sorted.
profile_env() {
  yq -r 'select(.kind == "Job" and .metadata.labels."app.kubernetes.io/component" == "hoopdb-migrate") | .spec.template.spec.containers[0].env[] | select(.value != null) | .name + "=" + .value' <<<"$out" \
    | grep -E "^($(tr ' ' '|' <<<"$PROFILE_ENV"))=" | sort
}

expect_fail() { # message helm-args...
  local msg=$1 o; shift
  if o=$(render "$@" 2>&1); then err "rendered despite: $msg"
  elif ! grep -qF "$msg" <<<"$o"; then err "wrong error for \"$msg\": $(grep -m1 Error <<<"$o")"; fi
}

for row in "${MATRIX[@]}"; do
  IFS='|' read -r rel cluster locker dbmode shape <<<"$row"
  f="$CHART/$rel"; label="96bulls ($rel)"
  [ -f "$f" ] || { err "$label: profile file missing"; continue; }
  args=(-f "$f")
  if [[ $rel == profiles/* ]]; then
    args+=("${REQUIRED[@]}")
    # Operator inputs the profile leaves empty must fail the render; then supply them.
    case $shape in
      external)
        expect_fail "migrations.runtimeRole is required" "${args[@]}"
        expect_fail "migrations.runtimeRoleLogin must be set (true or false) in $dbmode mode" "${args[@]}" --set worker.migrations.runtimeRole=bulls96_runtime
        args+=("${RUNTIME[@]}") ;;
      supabase)
        # Fail-closed: the profile itself does not render.
        expect_fail "supabaseActivation.hold: the external-Supabase profile is fail-closed" "${args[@]}"
        args+=(--set supabaseActivation.hold=false) ;;
    esac
  fi
  echo "--- $mode: $label"
  helm lint --strict "$CHART" "${args[@]}" >/dev/null || { helm lint --strict "$CHART" "${args[@]}"; err "$label: helm lint --strict failed"; continue; }
  out=$(render "${args[@]}") || { err "$label: render failed"; continue; }

  # App workloads and the migrate Job, in every profile.
  for d in ci-worker-referee ci-worker-bob-costas ci-worker-hoopdb-indexer ci-alleyoop-ingest; do
    has ".kind == \"Deployment\" and .metadata.name == \"$d\"" || err "$label: Deployment $d missing"
  done
  has ".kind == \"Job\" and $(comp hoopdb-migrate)" || err "$label: migrate Job missing"
  none '.metadata.annotations."helm.sh/hook"' || err "$label: a Helm hook rendered"
  mig=$(yq "select(.kind == \"Job\" and $(comp hoopdb-migrate))" <<<"$out")
  [ "$(yq -r '.spec.template.spec.containers[0].env[] | select(.name == "HOOPDB_ROLE_VERIFY") | .value' <<<"$mig")" = true ] || err "$label: migrate does not run the phase 2 role verify"

  # The migrator profile (#99): exactly this env in migrate, nowhere else.
  case $dbmode in
    selfhosted) want=$'HOOPDB_DB_MODE=selfhosted\nHOOPDB_FUNCTION_BOUNDARY_MODE=global-default-revoke\nHOOPDB_RUNTIME_ROLE=bulls96_runtime\nHOOPDB_RUNTIME_ROLE_LOGIN=true\nHOOPDB_SUPABASE_SHIM=true' ;;
    cloudsql)   want=$'HOOPDB_DB_MODE=cloudsql\nHOOPDB_FUNCTION_BOUNDARY_MODE=global-default-revoke\nHOOPDB_ROLE_BOOTSTRAP=false\nHOOPDB_RUNTIME_ROLE=bulls96_runtime\nHOOPDB_RUNTIME_ROLE_LOGIN=true\nHOOPDB_SUPABASE_SHIM=false' ;;
    supabase)   want=$'HOOPDB_DB_MODE=supabase\nHOOPDB_RUNTIME_ROLE=bulls96_runtime\nHOOPDB_RUNTIME_ROLE_LOGIN=true\nHOOPDB_SUPABASE_SHIM=false' ;;
  esac
  got=$(profile_env)
  [ "$got" = "$want" ] || err "$label: migrate profile env is [$(tr '\n' ' ' <<<"$got")], want [$(tr '\n' ' ' <<<"$want")]"
  for n in $PROFILE_ENV HOOPDB_FUNCTION_BOUNDARY_APPROVED; do
    c=$(yq -r "[.. | select(type == \"!!map\" and .name == \"$n\" and has(\"value\"))] | length" <<<"$out" | awk '{s+=$1} END {print s+0}')
    case $n in HOOPDB_FUNCTION_BOUNDARY_APPROVED) w=0 ;; *) w=$(grep -c "^$n=" <<<"$want" || true) ;; esac
    [ "$c" = "$w" ] || err "$label: $n rendered $c times, want $w (migrate only)"
  done

  # HoopDb.
  if [ "$cluster" = yes ]; then
    has '.kind == "Cluster" and .metadata.name == "hoopdb"' || err "$label: HoopDb Cluster missing"
    [ "$(yq -r 'select(.kind == "Cluster") | .spec.enableSuperuserAccess' <<<"$out")" = false ] || err "$label: enableSuperuserAccess is not false"
  else
    none '.kind == "Cluster"' || err "$label: a HoopDb Cluster rendered for an external database"
  fi

  # Locker.
  if [ "$locker" = yes ]; then
    has '.kind == "Deployment" and .metadata.name == "locker"' || err "$label: Locker Deployment missing"
    has ".kind == \"Job\" and $(comp locker-init)" || err "$label: locker-init Job missing"
  else
    none '.kind == "Deployment" and .metadata.name == "locker"' || err "$label: Locker rendered with locker disabled"
  fi

  # The bootstrap path: which privileged Jobs, and what migrate waits for.
  case $shape in
    fresh)    jobs="hoopdb-runtime-role-bootstrap hoopdb-function-default-revoke"; roles="session_directory_search_worker bulls96_runtime"; fd=true ;;
    existing) jobs="search-worker-role-bootstrap hoopdb-runtime-role-bootstrap hoopdb-function-default-revoke"; roles="session_directory_search_worker bulls96_runtime"; fd=true ;;
    external) jobs=""; roles="session_directory_search_worker bulls96_runtime"; fd=false ;;
    supabase) jobs=""; roles=""; fd="" ;;
  esac
  for c in search-worker-role-bootstrap hoopdb-runtime-role-bootstrap hoopdb-function-default-revoke; do
    if [[ " $jobs " == *" $c "* ]]; then
      for k in Job ServiceAccount Role RoleBinding; do
        [ "$(count ".kind == \"$k\" and $(comp "$c")")" = 1 ] || err "$label: exactly one $c $k expected"
      done
      [ "$(yq -o=json -I=0 "select(.kind == \"Role\" and $(comp "$c")) | .rules" <<<"$out")" = '[{"apiGroups":[""],"resources":["pods"],"verbs":["get","list"]},{"apiGroups":[""],"resources":["pods/exec"],"verbs":["create"]}]' ] || err "$label: $c Role is not pods get/list + pods/exec create"
    else
      none "$(comp "$c")" || err "$label: $c objects rendered ($shape shape)"
    fi
  done
  none '.kind == "ClusterRole" or .kind == "ClusterRoleBinding"' || err "$label: cluster-scoped RBAC rendered"
  args0() { yq -r "select(.kind == \"Job\" and $(comp "$1")) | .spec.template.spec.containers[0].args[0]" <<<"$out"; }
  if [[ " $jobs " == *" hoopdb-function-default-revoke "* ]]; then
    args0 hoopdb-function-default-revoke | grep -qF "psql -v ON_ERROR_STOP=1 -v VERBOSITY=verbose -v 'migration_owner=hoop' -X" || err "$label: function-default Job does not pass -v migration_owner=hoop"
    [ "$(yq -r "select(.kind == \"Job\" and $(comp hoopdb-function-default-revoke)) | .spec.template.spec.initContainers[0].command | join(\" \")" <<<"$out")" = "cp /app/supabase/bootstrap/hoopdb_function_default_revoke.sql /work/bootstrap.sql" ] || err "$label: function-default Job copies the wrong file"
  fi
  if [[ " $jobs " == *" hoopdb-runtime-role-bootstrap "* ]]; then
    args0 hoopdb-runtime-role-bootstrap | grep -qF -- "-v 'runtime_role=bulls96_runtime' -v 'runtime_login=true' -X" || err "$label: runtime-role Job does not pass runtime_role/runtime_login"
  fi
  if [ "$shape" = fresh ] || [ "$shape" = existing ]; then
    sql=$(yq -r 'select(.kind == "Cluster") | .spec.bootstrap.initdb.postInitApplicationSQL[]' <<<"$out")
    grep -qxF "$ROLE_SQL" <<<"$sql" || err "$label: initdb SQL does not create the search Worker role"
  fi
  w0=$(yq -r '.spec.template.spec.initContainers[0].name // ""' <<<"$mig")
  if [ -z "$roles" ]; then
    [ "$w0" != wait-for-role ] || err "$label: migrate waits for roles in $shape shape"
  else
    [ "$w0" = wait-for-role ] || err "$label: migrate does not wait for the roles"
    [ "$(yq -r '.spec.template.spec.initContainers[0].env[] | select(.name == "ROLES") | .value' <<<"$mig")" = "$roles" ] || err "$label: wait-for-role waits for the wrong roles"
    [ "$(yq -r '.spec.template.spec.initContainers[0].env[] | select(.name == "FUNCTION_DEFAULT") | .value' <<<"$mig")" = "$fd" ] || err "$label: wait-for-role FUNCTION_DEFAULT is not $fd"
  fi

  if [ "$mode" = dryrun ]; then
    render --include-crds "${args[@]}" \
      | kubectl apply --server-side --dry-run=server --field-manager=profile-matrix -n ci -f - >/dev/null \
      || err "$label: server-side dry-run apply failed"
  fi
done

# The external-Supabase profile: bulls96_runtime with LOGIN and no workload
# role (never the drifted legacy relayhistory_runtime), the Worker pinned to
# session_directory_search_worker, and fail-closed: no function boundary mode,
# so migrate refuses (function_boundary_unproven) before any write.
SBP="$CHART/profiles/external-supabase.yaml"
[ "$(yq -r '[.worker.migrations.runtimeRole, .worker.migrations.runtimeRoleLogin, (.worker.migrations.runtimeWorkloadRole // ""), (.worker.migrations.functionBoundaryMode // ""), .worker.migrations.waitForRole.role] | map(tostring) | join("|")' "$SBP")" = "bulls96_runtime|true|||session_directory_search_worker" ] \
  || err "profiles/external-supabase.yaml: runtime bulls96_runtime LOGIN, no workload role, no boundary mode (fail-closed), Worker session_directory_search_worker"
grep -q relayhistory_runtime <(yq -r '.. | select(tag == "!!str")' "$SBP") && err "profiles/external-supabase.yaml: uses relayhistory_runtime"

# Mode combinations the chart must refuse (the migrator's refusals at render
# time, plus the chart's in-cluster rules). Bases: an in-cluster selfhosted
# file, AWS external Supabase, GCP Cloud SQL.
if [ "$mode" = static ]; then
  echo "--- static: refused combinations"
  IN=(-f "$CHART/ci/default-values.yaml")
  SB=(-f "$CHART/ci/pod-identity-values.yaml")
  GCP=(-f "$CHART/ci/gcp-cloudsql-values.yaml")
  expect_fail "databaseMode must be local, selfhosted, cloudsql or supabase" "${IN[@]}" --set worker.migrations.databaseMode=
  expect_fail "worker.migrations.databaseMode must be selfhosted, not \"supabase\"" "${IN[@]}" --set worker.migrations.databaseMode=supabase --set worker.migrations.supabaseShim=false --set worker.migrations.waitForRole.enabled=false --set worker.migrations.waitForRole.functionDefault=false
  expect_fail "worker.migrations.databaseMode must be selfhosted, not \"local\"" "${IN[@]}" --set worker.migrations.databaseMode=local
  expect_fail "supabaseShim must not be true in supabase mode" "${SB[@]}" --set worker.migrations.supabaseShim=true
  expect_fail "waitForRole must be disabled in supabase mode" "${SB[@]}" --set worker.migrations.waitForRole.enabled=true
  expect_fail "functionDefaultRevoke.bootstrapJob is for the in-cluster CNPG HoopDb only" "${SB[@]}" --set functionDefaultRevoke.bootstrapJob.enabled=true
  expect_fail "runtimeRole.bootstrapJob is for the in-cluster HoopDb only" "${SB[@]}" --set runtimeRole.bootstrapJob.enabled=true
  expect_fail "functionDefaultRevoke.bootstrapJob is for the in-cluster CNPG HoopDb only" "${GCP[@]}" --set functionDefaultRevoke.bootstrapJob.enabled=true
  expect_fail "runtimeRoleLogin must be set (true or false) in supabase mode" "${SB[@]}" --set worker.migrations.runtimeRoleLogin=null
  expect_fail "supabaseShim must be set (true or false) in cloudsql mode" "${GCP[@]}" --set worker.migrations.supabaseShim=null
  expect_fail "functionBoundaryMode is required in cloudsql mode" "${GCP[@]}" --set worker.migrations.functionBoundaryMode=
  expect_fail "functionBoundaryMode is required in selfhosted mode" "${IN[@]}" --set worker.migrations.functionBoundaryMode=
  expect_fail "databaseMode must be local, selfhosted, cloudsql or supabase" "${GCP[@]}" --set worker.migrations.databaseMode=cloud
  expect_fail "roleBootstrap must not be true in supabase mode" "${SB[@]}" --set worker.migrations.roleBootstrap=true
  expect_fail "roleBootstrap must be true or false" "${GCP[@]}" --set-string worker.migrations.roleBootstrap=no
  expect_fail "worker.migrations.databaseMode must be selfhosted, not \"cloudsql\"" "${IN[@]}" --set worker.migrations.databaseMode=cloudsql
  expect_fail "functionBoundaryMode=event-trigger is not implemented" "${GCP[@]}" --set worker.migrations.functionBoundaryMode=event-trigger
  expect_fail "functionBoundaryMode=event-trigger is not implemented" "${SB[@]}" --set worker.migrations.functionBoundaryMode=event-trigger
  expect_fail "functionBoundaryMode must be global-default-revoke" "${SB[@]}" --set worker.migrations.functionBoundaryMode=yes
  expect_fail "functionBoundaryApproved was renamed functionBoundaryMode" "${SB[@]}" --set worker.migrations.functionBoundaryApproved=global-default-revoke
  expect_fail "functionDefaultRevoke.bootstrapJob.enabled must be true with the in-cluster HoopDb" "${IN[@]}" --set functionDefaultRevoke.bootstrapJob.enabled=false
  expect_fail "runtimeRole.bootstrapJob.enabled must be true with the in-cluster HoopDb" "${IN[@]}" --set runtimeRole.bootstrapJob.enabled=false
  expect_fail "needs worker.migrations.waitForRole.functionDefault=true" "${IN[@]}" --set worker.migrations.waitForRole.functionDefault=false
  expect_fail "runtimeRole must not be the migration owner \"hoop\"" "${IN[@]}" --set worker.migrations.runtimeRole=hoop
  expect_fail "runtimeRole must not be the search Worker role" "${GCP[@]}" --set worker.migrations.runtimeRole=session_directory_search_worker
  for n in HOOPDB_DB_MODE HOOPDB_SUPABASE_SHIM HOOPDB_RUNTIME_ROLE HOOPDB_RUNTIME_ROLE_LOGIN HOOPDB_FUNCTION_BOUNDARY_MODE HOOPDB_FUNCTION_BOUNDARY_APPROVED HOOPDB_ROLE_BOOTSTRAP; do
    expect_fail "extraEnv must not set $n" "${GCP[@]}" --set "worker.extraEnv[0].name=$n" --set "worker.extraEnv[0].value=x"
  done
fi

[ $fail -eq 0 ] && echo "96bulls profile matrix ($mode): OK (${#MATRIX[@]} profiles)"
exit $fail
