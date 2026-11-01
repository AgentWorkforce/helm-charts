#!/usr/bin/env bash
# Bootstrap/render matrix for charts/96bulls: every shipped profile
# (charts/96bulls/profiles/*.yaml) and every CI values profile
# (charts/96bulls/ci/*-values.yaml) is rendered the way Alchemy installs
# (helm template --no-hooks) and checked for the manifests that profile must
# produce: the app workloads, the migrate Job, HoopDb and its role bootstrap
# path (initdb SQL on a new cluster, the bootstrap Job on an existing one),
# and Locker. A profile without a row below fails the matrix.
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

# The inputs a shipped profile leaves to the operator (CI values files carry
# their own). The digest is a CI placeholder
# (no image is pulled); no services image is pinned by this repo.
REQUIRED=(--set global.tenant.orgId=org_ci --set alleyoop.auth.jwksUrl=https://relayauth.example.com/.well-known/jwks.json)
PLACEHOLDER_DIGEST="sha256:$(printf '%064d' 1)"

# profile file (relative to charts/96bulls) | HoopDb Cluster | Locker | role bootstrap path
#   bootstrap: initdb = new cluster, the role comes from initdb SQL, no Job
#              job    = existing cluster, the bootstrap Job + its RBAC render
#              none   = external database, neither (pre-provisioned)
MATRIX=(
  "profiles/selfhost-postgres.yaml|yes|yes|initdb"
  "profiles/migration.yaml|yes|yes|job"
  "ci/default-values.yaml|yes|yes|initdb"
  "ci/kind-values.yaml|yes|yes|initdb"
  "ci/pod-identity-values.yaml|no|no|none"
  "ci/search-worker-bootstrap-values.yaml|yes|yes|job"
)

# Every profile on disk has a row (a new profile cannot skip the matrix).
for f in "$CHART"/profiles/*.yaml "$CHART"/ci/*-values.yaml; do
  rel=${f#"$CHART"/}
  printf '%s\n' "${MATRIX[@]}" | cut -d'|' -f1 | grep -qxF "$rel" || err "$rel: no row in the profile matrix"
done

# Shipped profiles never pin a 96Bulls services image (tag or digest): the
# operator supplies the release they deploy.
for f in "$CHART"/profiles/*.yaml; do
  pins=$(yq -r '[.worker.image.tag, .worker.image.digest, .alleyoop.image.tag, .alleyoop.image.digest, .searchWorkerRole.bootstrapJob.sqlImage.digest] | map(select(. != null and . != "")) | join(",")' "$f")
  [ -z "$pins" ] || err "${f#"$CHART"/}: pins a services image ($pins)"
done

BOOT='"search-worker-role-bootstrap"'
ROLE_SQL="CREATE ROLE session_directory_search_worker NOLOGIN NOINHERIT NOBYPASSRLS NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION"
count() { yq "select($1)" <<<"$out" | yq -N 'select(. != null) | .kind' | grep -c . || true; }
has() { [ "$(count "$1")" -ge 1 ]; }
none() { [ "$(count "$1")" -eq 0 ]; }

for row in "${MATRIX[@]}"; do
  IFS='|' read -r rel cluster locker boot <<<"$row"
  f="$CHART/$rel"; label="96bulls ($rel)"
  [ -f "$f" ] || { err "$label: profile file missing"; continue; }
  args=(-f "$f"); [[ $rel == profiles/* ]] && args+=("${REQUIRED[@]}")
  if [ "$boot" = job ] && [ -z "$(yq -r '.searchWorkerRole.bootstrapJob.sqlImage.digest // ""' "$f")" ]; then
    # The profile leaves the services image digest to the operator: without
    # it the render must fail, with it the profile renders.
    if o=$(helm template ci "$CHART" --namespace ci --no-hooks "${args[@]}" 2>&1); then
      err "$label: rendered without the services image digest"
    elif ! grep -qF "sqlImage.repository and .digest are required" <<<"$o"; then
      err "$label: wrong error without the digest: $o"
    fi
    args+=(--set "searchWorkerRole.bootstrapJob.sqlImage.digest=$PLACEHOLDER_DIGEST")
  fi
  echo "--- $mode: $label"
  helm lint --strict "$CHART" "${args[@]}" >/dev/null || { helm lint --strict "$CHART" "${args[@]}"; err "$label: helm lint --strict failed"; continue; }
  out=$(helm template ci "$CHART" --namespace ci --no-hooks "${args[@]}") || { err "$label: render failed"; continue; }

  # App workloads and the migrate Job, in every profile.
  for d in ci-worker-referee ci-worker-bob-costas ci-worker-hoopdb-indexer ci-alleyoop-ingest; do
    has ".kind == \"Deployment\" and .metadata.name == \"$d\"" || err "$label: Deployment $d missing"
  done
  has '.kind == "Job" and .metadata.labels."app.kubernetes.io/component" == "hoopdb-migrate"' || err "$label: migrate Job missing"
  none '.metadata.annotations."helm.sh/hook"' || err "$label: a Helm hook rendered"
  mig=$(yq 'select(.kind == "Job" and .metadata.labels."app.kubernetes.io/component" == "hoopdb-migrate")' <<<"$out")
  [ "$(yq -r '.spec.template.spec.containers[0].env[] | select(.name == "HOOPDB_ROLE_VERIFY") | .value' <<<"$mig")" = true ] || err "$label: migrate does not run the phase 2 role verify"

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
    has '.kind == "Job" and .metadata.labels."app.kubernetes.io/component" == "locker-init"' || err "$label: locker-init Job missing"
  else
    none '.kind == "Deployment" and .metadata.name == "locker"' || err "$label: Locker rendered with locker disabled"
  fi

  # The role bootstrap path.
  sql=$(yq -r 'select(.kind == "Cluster") | .spec.bootstrap.initdb.postInitApplicationSQL[]' <<<"$out")
  case $boot in
    initdb|job)
      grep -qxF "$ROLE_SQL" <<<"$sql" || err "$label: initdb SQL does not create the search Worker role"
      [ "$(yq -r '.spec.template.spec.initContainers[0].name' <<<"$mig")" = wait-for-role ] || err "$label: migrate does not wait for the role"
      ;;
  esac
  if [ "$boot" = job ]; then
    for k in Job ServiceAccount Role RoleBinding; do
      [ "$(count ".kind == \"$k\" and .metadata.labels.\"app.kubernetes.io/component\" == $BOOT")" = 1 ] || err "$label: exactly one bootstrap $k expected"
    done
    none "(.kind == \"ClusterRole\" or .kind == \"ClusterRoleBinding\") and .metadata.labels.\"app.kubernetes.io/component\" == $BOOT" || err "$label: cluster-scoped bootstrap RBAC rendered"
  else
    none ".metadata.labels.\"app.kubernetes.io/component\" == $BOOT" || err "$label: bootstrap objects rendered ($boot profile)"
  fi

  if [ "$mode" = dryrun ]; then
    helm template ci "$CHART" --namespace ci --no-hooks --include-crds "${args[@]}" \
      | kubectl apply --server-side --dry-run=server --field-manager=profile-matrix -n ci -f - >/dev/null \
      || err "$label: server-side dry-run apply failed"
  fi
done

[ $fail -eq 0 ] && echo "96bulls profile matrix ($mode): OK (${#MATRIX[@]} profiles)"
exit $fail
