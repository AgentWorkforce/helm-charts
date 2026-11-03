#!/usr/bin/env bash
# jq programs are intentionally single-quoted.
# shellcheck disable=SC2016
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

MODE="audit"
APPLY_REQUESTED=false
APPROVAL="${CONFORMANCE_APPROVAL:-}"
RUN_ID="${CONFORMANCE_RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)-$$}"
RELEASE_NAME="${CONFORMANCE_RELEASE:-agentworkforce-conformance}"
RUN_NAMESPACE="${CONFORMANCE_NAMESPACE:-aw-conformance-$(printf '%s' "${RUN_ID}" | tr '[:upper:]' '[:lower:]')}"
CHART="${CONFORMANCE_CHART:-}"
CURRENT_VERSION="${CONFORMANCE_CURRENT_VERSION:-}"
PREVIOUS_VERSION="${CONFORMANCE_PREVIOUS_VERSION:-}"
TIMEOUT="${CONFORMANCE_TIMEOUT:-10m}"
EVIDENCE_DIR="${CONFORMANCE_EVIDENCE_DIR:-${SCRIPT_DIR}/evidence/${RUN_ID}}"
CONFORMANCE_ADAPTER="${CONFORMANCE_ADAPTER:-}"
CONFORMANCE_BASE_URL="${CONFORMANCE_BASE_URL:-}"
CONFORMANCE_DNS_NAME="${CONFORMANCE_DNS_NAME:-}"
CONFORMANCE_HEALTH_PATH="${CONFORMANCE_HEALTH_PATH:-/readyz}"
MIGRATION_FAILURE_VALUES="${CONFORMANCE_MIGRATION_FAILURE_VALUES:-}"
WRONG_DATABASE_VALUES="${CONFORMANCE_WRONG_DATABASE_VALUES:-}"
DB_OUTAGE_HOOK="${CONFORMANCE_DB_OUTAGE_HOOK:-}"
DB_DEPENDENT_SELECTOR="${CONFORMANCE_DB_DEPENDENT_SELECTOR:-}"
BACKUP_HOOK="${CONFORMANCE_BACKUP_HOOK:-}"
RESTORE_HOOK="${CONFORMANCE_RESTORE_HOOK:-}"
ROLLBACK_BASE_URL="${CONFORMANCE_ROLLBACK_BASE_URL:-}"
TARGET_NAMESPACE="${CONFORMANCE_TARGET_NAMESPACE:-}"
TARGET_RELEASE="${CONFORMANCE_TARGET_RELEASE:-}"
CLEANUP=false
DB_OUTAGE_ACTIVE=false
FRESH_INSTALL_OK=false
VALUES_FILES=()
CREATED_NAMESPACES=()
STARTED_AT="$(utc_now)"

usage() {
  cat <<'EOF'
Usage: run.sh [options]

Safe by default: audit mode performs only read-only checks and Helm dry-runs.
Cluster or application mutation requires both --apply and approval APPLY.

Core options:
  --chart REF                     Umbrella chart path, repository ref, or OCI ref
  --current-version VERSION       Current chart version (optional for local chart)
  --previous-version VERSION      Previous chart version
  --values FILE                   Values file; repeatable
  --release NAME                  Conformance release prefix
  --namespace NAME                Conformance namespace prefix
  --target-namespace NAME         Existing release namespace for read-only
                                  audit checks (rejected with --apply)
  --target-release NAME           Existing release name for read-only audit
                                  checks (rejected with --apply)
  --adapter FILE                  Executable implementing product assertions
  --base-url HTTPS_URL            Existing or installed service URL
  --dns-name HOST                 DNS hostname to resolve
  --evidence-dir DIR              Machine-readable evidence destination
  --timeout DURATION              Helm/kubectl timeout (default: 10m)

Failure and recovery fixtures:
  --migration-failure-values FILE Values that force a migration failure
  --wrong-database-values FILE    Values that configure a known-wrong database
  --db-outage-hook FILE           Executable supporting begin/end actions
  --db-dependent-selector SEL     Pods that must go unready during the DB
                                  outage (default: the release's api and
                                  history components; Job pods are always
                                  excluded)
  --backup-hook FILE              Executable supporting create action
  --restore-hook FILE             Executable supporting restore/verify actions
  --rollback-base-url HTTPS_URL   Side-by-side previous-version service URL

Mutation gate:
  --apply                         Request mutation mode
  --approval APPLY                Required literal approval
  --cleanup                       Delete only namespaces created by this run

Other:
  -h, --help
EOF
}

while (($#)); do
  case "$1" in
    --chart) CHART="${2:?missing value for --chart}"; shift 2 ;;
    --current-version) CURRENT_VERSION="${2:?missing value for --current-version}"; shift 2 ;;
    --previous-version) PREVIOUS_VERSION="${2:?missing value for --previous-version}"; shift 2 ;;
    --values) VALUES_FILES+=("${2:?missing value for --values}"); shift 2 ;;
    --release) RELEASE_NAME="${2:?missing value for --release}"; shift 2 ;;
    --namespace) RUN_NAMESPACE="${2:?missing value for --namespace}"; shift 2 ;;
    --target-namespace) TARGET_NAMESPACE="${2:?missing value for --target-namespace}"; shift 2 ;;
    --target-release) TARGET_RELEASE="${2:?missing value for --target-release}"; shift 2 ;;
    --adapter) CONFORMANCE_ADAPTER="${2:?missing value for --adapter}"; shift 2 ;;
    --base-url) CONFORMANCE_BASE_URL="${2:?missing value for --base-url}"; shift 2 ;;
    --dns-name) CONFORMANCE_DNS_NAME="${2:?missing value for --dns-name}"; shift 2 ;;
    --evidence-dir) EVIDENCE_DIR="${2:?missing value for --evidence-dir}"; shift 2 ;;
    --timeout) TIMEOUT="${2:?missing value for --timeout}"; shift 2 ;;
    --migration-failure-values) MIGRATION_FAILURE_VALUES="${2:?missing value for --migration-failure-values}"; shift 2 ;;
    --wrong-database-values) WRONG_DATABASE_VALUES="${2:?missing value for --wrong-database-values}"; shift 2 ;;
    --db-outage-hook) DB_OUTAGE_HOOK="${2:?missing value for --db-outage-hook}"; shift 2 ;;
    --db-dependent-selector) DB_DEPENDENT_SELECTOR="${2:?missing value for --db-dependent-selector}"; shift 2 ;;
    --backup-hook) BACKUP_HOOK="${2:?missing value for --backup-hook}"; shift 2 ;;
    --restore-hook) RESTORE_HOOK="${2:?missing value for --restore-hook}"; shift 2 ;;
    --rollback-base-url) ROLLBACK_BASE_URL="${2:?missing value for --rollback-base-url}"; shift 2 ;;
    --apply) APPLY_REQUESTED=true; shift ;;
    --approval) APPROVAL="${2:-}"; shift 2 ;;
    --cleanup) CLEANUP=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

if [[ "${APPLY_REQUESTED}" == true ]]; then
  [[ "${APPROVAL}" == "APPLY" ]] ||
    die "--apply requires --approval APPLY (or CONFORMANCE_APPROVAL=APPLY)"
  MODE="apply"
elif [[ -n "${APPROVAL}" ]]; then
  die "approval was supplied without --apply"
fi

# Apply mode mutates whatever release it points at (outage hooks, rollout
# restarts, adapter fixtures). It must only ever act on the isolated release it
# installs itself, so an existing target is accepted for audit mode only.
if [[ "${MODE}" == "apply" && ( -n "${TARGET_NAMESPACE}" || -n "${TARGET_RELEASE}" ) ]]; then
  die "--target-namespace/--target-release are read-only audit inputs and cannot be combined with --apply"
fi

[[ "${RUN_NAMESPACE}" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] ||
  die "namespace must be a DNS label"
((${#RUN_NAMESPACE} <= 53)) ||
  die "namespace prefix must be at most 53 characters to allow isolated suffixes"
[[ "${RELEASE_NAME}" =~ ^[a-zA-Z0-9]([-a-zA-Z0-9.]*[a-zA-Z0-9])?$ ]] ||
  die "invalid Helm release name"
((${#RELEASE_NAME} <= 43)) ||
  die "release prefix must be at most 43 characters to allow isolated suffixes"
[[ "${TIMEOUT}" =~ ^[1-9][0-9]*(s|m|h)$ ]] || die "invalid timeout"
for values_file in ${VALUES_FILES[@]+"${VALUES_FILES[@]}"}; do
  [[ -f "${values_file}" ]] || die "values file not found: ${values_file}"
done

require_command jq
require_command helm
require_command kubectl
init_evidence

ACTIVE_NAMESPACE="${TARGET_NAMESPACE:-${RUN_NAMESPACE}}"
ACTIVE_RELEASE="${TARGET_RELEASE:-${RELEASE_NAME}}"
export MODE RUN_ID RUN_NAMESPACE RELEASE_NAME ACTIVE_NAMESPACE ACTIVE_RELEASE
export CONFORMANCE_ADAPTER CONFORMANCE_BASE_URL

on_exit() {
  local original_rc=$?
  local ended_at
  if [[ "${DB_OUTAGE_ACTIVE}" == true ]] && validate_hook "${DB_OUTAGE_HOOK}"; then
    run_hook "${DB_OUTAGE_HOOK}" end || true
    DB_OUTAGE_ACTIVE=false
  fi
  ended_at="$(utc_now)"
  finalize_evidence "${ended_at}"
  if [[ "${original_rc}" -eq 0 ]] && jq -e '.success == false' "${SUMMARY_JSON}" >/dev/null; then
    original_rc=1
  fi
  printf 'Evidence: %s\n' "${SUMMARY_JSON}"
  exit "${original_rc}"
}
trap on_exit EXIT

helm_values_args() {
  local values_file
  HELM_VALUES_ARGS=()
  for values_file in ${VALUES_FILES[@]+"${VALUES_FILES[@]}"}; do
    HELM_VALUES_ARGS+=("--values" "${values_file}")
  done
}

helm_version_args() {
  local version="$1"
  HELM_VERSION_ARGS=()
  [[ -n "${version}" ]] && HELM_VERSION_ARGS+=("--version" "${version}")
}

create_namespace() {
  local namespace="$1"
  if run_quiet safe_kubectl create namespace "${namespace}"; then
    CREATED_NAMESPACES+=("${namespace}")
    run_quiet safe_kubectl label namespace "${namespace}" \
      "app.kubernetes.io/managed-by=agentworkforce-conformance" \
      "conformance.agentworkforce.dev/run-id=${RUN_ID}" --overwrite
    return 0
  fi
  return 1
}

# helm_install_mode atomic|keep RELEASE NAMESPACE VERSION [extra helm args...]
# "keep" leaves failed resources in place so negative scenarios can inspect
# why the release failed before cleaning up.
helm_install_mode() {
  local rollback_mode="$1"
  local release="$2"
  local namespace="$3"
  local version="$4"
  shift 4
  local atomic_args=()
  [[ "${rollback_mode}" == "atomic" ]] && atomic_args=(--atomic)
  helm_values_args
  helm_version_args "${version}"
  # Migration Jobs are plain (non-hook) Jobs; --wait alone does not wait for
  # them, so a running or failed migration could otherwise report success.
  run_quiet safe_helm upgrade --install "${release}" "${CHART}" \
    --namespace "${namespace}" \
    ${atomic_args[@]+"${atomic_args[@]}"} --wait --wait-for-jobs \
    --timeout "${TIMEOUT}" --hide-secret \
    ${HELM_VERSION_ARGS[@]+"${HELM_VERSION_ARGS[@]}"} ${HELM_VALUES_ARGS[@]+"${HELM_VALUES_ARGS[@]}"} "$@"
}

install_release() {
  helm_install_mode atomic "$@"
}

install_release_keep_failure() {
  helm_install_mode keep "$@"
}

# Print a JSON object classifying why release pods are not healthy:
#   unrelated: pods blocked by image, config, or scheduling problems, which
#              say nothing about the database fixture
#   app_failed: workload containers that started and then stayed unready,
#              exited non-zero, or crash-looped (the expected signal when
#              the application cannot use its database)
classify_release_pods() {
  local release="$1"
  local namespace="$2"
  local pods_json=""
  pods_json="$(safe_kubectl get pods --namespace "${namespace}" \
    --selector "app.kubernetes.io/instance=${release}" --output json 2>/dev/null)" ||
    return 1
  jq -ce '
    def statuses: ((.status.initContainerStatuses // []) + (.status.containerStatuses // []));
    def unrelated_reason:
      ["ErrImagePull", "ImagePullBackOff", "InvalidImageName",
       "CreateContainerConfigError", "CreateContainerError", "RunContainerError"];
    (.items // []) as $pods
    | {
        pods: ($pods | length),
        unrelated: [
          $pods[]
          | select(
              any(statuses[]; (.state.waiting.reason // "") as $r | any(unrelated_reason[]; . == $r))
              or any((.status.conditions // [])[]; .type == "PodScheduled" and .status == "False")
            )
        ] | length,
        app_failed: [
          $pods[]
          | select(
              any(statuses[];
                (.state.running != null and .ready != true)
                or ((.state.terminated.exitCode // 0) != 0)
                or ((.lastState.terminated.exitCode // 0) != 0)
                or ((.state.waiting.reason // "") == "CrashLoopBackOff"))
            )
        ] | length
      }
  ' <<<"${pods_json}"
}

# Print the number of failed migration Jobs for a release. Migration Jobs are
# identified by name or by their pod template component label.
count_failed_migration_jobs() {
  local release="$1"
  local namespace="$2"
  local jobs_json=""
  jobs_json="$(safe_kubectl get jobs.batch --namespace "${namespace}" \
    --selector "app.kubernetes.io/instance=${release}" --output json 2>/dev/null)" ||
    return 1
  jq -e '
    [ (.items // [])[]
      | select(
          ((.metadata.name // "") | test("migrat"; "i"))
          or ((.spec.template.metadata.labels["app.kubernetes.io/component"] // "") == "migration")
        )
      | select(any((.status.conditions // [])[]; .type == "Failed" and .status == "True"))
    ] | length
  ' <<<"${jobs_json}"
}

deployed_chart_matches_version() {
  local release="$1"
  local namespace="$2"
  local version="$3"
  local releases_json=""
  [[ -n "${version}" ]] || return 0
  releases_json="$(safe_helm list --namespace "${namespace}" \
    --filter "^${release}$" --output json 2>/dev/null)" || return 1
  jq -e --arg release "${release}" --arg version "${version}" \
    'any(.[]; .name == $release and .status == "deployed"
      and ((.chart // "") | endswith("-" + $version)))' \
    >/dev/null 2>&1 <<<"${releases_json}"
}

dry_run_release() {
  helm_values_args
  helm_version_args "${CURRENT_VERSION}"
  run_quiet safe_helm upgrade --install "${RELEASE_NAME}" "${CHART}" \
    --namespace "${RUN_NAMESPACE}" --dry-run --hide-secret \
    ${HELM_VERSION_ARGS[@]+"${HELM_VERSION_ARGS[@]}"} ${HELM_VALUES_ARGS[@]+"${HELM_VALUES_ARGS[@]}"}
}

release_is_deployed() {
  local release="$1"
  local namespace="$2"
  local releases_json=""
  if ! releases_json="$(safe_helm list --namespace "${namespace}" \
    --filter "^${release}$" --output json 2>/dev/null)"; then
    return 1
  fi
  jq -e --arg release "${release}" \
    'any(.[]; .name == $release and .status == "deployed")' \
    >/dev/null 2>&1 <<<"${releases_json}"
}

# Scenarios that mutate the active release (or ask hooks/adapters to) run only
# against the isolated release this run installed successfully.
require_isolated_release() {
  local scenario="$1"
  if [[ "${FRESH_INSTALL_OK}" != true ||
    "${ACTIVE_NAMESPACE}" != "${RUN_NAMESPACE}" ||
    "${ACTIVE_RELEASE}" != "${RELEASE_NAME}" ]]; then
    emit_evidence "${scenario}" "SKIP" "requires a successful isolated fresh install in this run"
    return 1
  fi
  return 0
}

scenario_preflight() {
  local failed=false
  run_quiet safe_kubectl version --client && run_quiet safe_helm version ||
    failed=true
  if [[ "${failed}" == false ]]; then
    emit_evidence "preflight" "PASS" "required clients are available"
  else
    emit_evidence "preflight" "FAIL" "client preflight failed"
  fi
}

scenario_fresh_install() {
  if [[ -z "${CHART}" ]]; then
    emit_evidence "fresh-install" "SKIP" "chart reference is not configured"
    return
  fi

  if [[ "${MODE}" == "audit" ]]; then
    if dry_run_release; then
      emit_evidence "fresh-install" "PASS" "Helm install dry-run passed with Secret output hidden"
    else
      emit_evidence "fresh-install" "FAIL" "Helm install dry-run failed"
    fi
    return
  fi

  if create_namespace "${RUN_NAMESPACE}" &&
    install_release "${RELEASE_NAME}" "${RUN_NAMESPACE}" "${CURRENT_VERSION}"; then
    ACTIVE_NAMESPACE="${RUN_NAMESPACE}"
    ACTIVE_RELEASE="${RELEASE_NAME}"
    FRESH_INSTALL_OK=true
    export ACTIVE_NAMESPACE ACTIVE_RELEASE
    emit_evidence "fresh-install" "PASS" "fresh isolated install became ready" \
      "$(json_object --arg namespace "${RUN_NAMESPACE}" --arg release "${RELEASE_NAME}" \
        '{namespace: $namespace, release: $release}')"
  else
    emit_evidence "fresh-install" "FAIL" "fresh isolated install failed"
  fi
}

scenario_upgrade() {
  local scenario="previous-version-upgrade"
  local namespace="${RUN_NAMESPACE}-upgrade"
  local release="${RELEASE_NAME}-upgrade"

  if [[ -z "${CHART}" || -z "${PREVIOUS_VERSION}" ]]; then
    emit_evidence "${scenario}" "SKIP" "chart and previous version are required"
    return
  fi
  require_apply "${scenario}" || return

  if create_namespace "${namespace}" &&
    install_release "${release}" "${namespace}" "${PREVIOUS_VERSION}" &&
    install_release "${release}" "${namespace}" "${CURRENT_VERSION}"; then
    emit_evidence "${scenario}" "PASS" "previous version upgraded in place"
  else
    emit_evidence "${scenario}" "FAIL" "previous-version upgrade failed"
  fi
}

scenario_migration_failure() {
  local scenario="migration-failure"
  local namespace="${RUN_NAMESPACE}-migration"
  local release="${RELEASE_NAME}-migration"

  if [[ -z "${CHART}" || -z "${PREVIOUS_VERSION}" || -z "${MIGRATION_FAILURE_VALUES}" ]]; then
    emit_evidence "${scenario}" "SKIP" "previous version and migration-failure values are required"
    return
  fi
  [[ -f "${MIGRATION_FAILURE_VALUES}" ]] || {
    emit_evidence "${scenario}" "FAIL" "migration-failure values file does not exist"
    return
  }
  require_apply "${scenario}" || return

  if ! create_namespace "${namespace}" ||
    ! install_release "${release}" "${namespace}" "${PREVIOUS_VERSION}"; then
    emit_evidence "${scenario}" "FAIL" "could not establish previous-version fixture"
    return
  fi

  # The upgrade is not atomic: an atomic rollback would delete the failed
  # migration Job before its failure could be attributed. The harness proves
  # the cause first, then rolls back explicitly.
  if install_release_keep_failure "${release}" "${namespace}" "${CURRENT_VERSION}" \
    --values "${MIGRATION_FAILURE_VALUES}"; then
    emit_evidence "${scenario}" "FAIL" "migration unexpectedly succeeded"
    return
  fi

  local failed_jobs="" pod_summary="" unrelated=0
  if ! failed_jobs="$(count_failed_migration_jobs "${release}" "${namespace}")"; then
    failed_jobs=0
  fi
  if pod_summary="$(classify_release_pods "${release}" "${namespace}")"; then
    unrelated="$(jq -r '.unrelated' <<<"${pod_summary}")"
  fi

  if ((failed_jobs == 0)); then
    emit_evidence "${scenario}" "FAIL" "upgrade failed but no migration Job reached Failed=True" \
      "$(json_object --argjson unrelated "${unrelated}" '{unrelated_pod_failures: $unrelated}')"
    run_quiet safe_helm rollback "${release}" --namespace "${namespace}" \
      --wait --wait-for-jobs --timeout "${TIMEOUT}" || true
    return
  fi
  if ((unrelated > 0)); then
    emit_evidence "${scenario}" "FAIL" "migration Job failed alongside unrelated image, config, or scheduling failures" \
      "$(json_object --argjson unrelated "${unrelated}" '{unrelated_pod_failures: $unrelated}')"
    run_quiet safe_helm rollback "${release}" --namespace "${namespace}" \
      --wait --wait-for-jobs --timeout "${TIMEOUT}" || true
    return
  fi

  if run_quiet safe_helm rollback "${release}" --namespace "${namespace}" \
    --wait --wait-for-jobs --timeout "${TIMEOUT}" &&
    release_is_deployed "${release}" "${namespace}" &&
    deployed_chart_matches_version "${release}" "${namespace}" "${PREVIOUS_VERSION}"; then
    emit_evidence "${scenario}" "PASS" "migration Job failed and rollback restored the previous deployed release" \
      "$(json_object --argjson failed_jobs "${failed_jobs}" '{failed_migration_jobs: $failed_jobs}')"
  else
    emit_evidence "${scenario}" "FAIL" "migration failed but the previous release was not restored"
  fi
}

scenario_wrong_database() {
  local scenario="wrong-database"
  local namespace="${RUN_NAMESPACE}-wrong-db"
  local release="${RELEASE_NAME}-wrong-db"

  if [[ -z "${CHART}" || -z "${WRONG_DATABASE_VALUES}" ]]; then
    emit_evidence "${scenario}" "SKIP" "wrong-database values are required"
    return
  fi
  [[ -f "${WRONG_DATABASE_VALUES}" ]] || {
    emit_evidence "${scenario}" "FAIL" "wrong-database values file does not exist"
    return
  }
  require_apply "${scenario}" || return
  # Baseline: the same chart, version, and base values must already have
  # become ready, so a failure below can be attributed to the overlay.
  if [[ "${FRESH_INSTALL_OK}" != true ]]; then
    emit_evidence "${scenario}" "SKIP" "requires a passing fresh install with the same base values as a baseline"
    return
  fi

  if ! create_namespace "${namespace}"; then
    emit_evidence "${scenario}" "FAIL" "could not create isolated namespace"
    return
  fi
  if install_release_keep_failure "${release}" "${namespace}" "${CURRENT_VERSION}" \
    --values "${WRONG_DATABASE_VALUES}"; then
    emit_evidence "${scenario}" "FAIL" "release became ready with a known-wrong database"
    return
  fi

  local pod_summary=""
  if ! pod_summary="$(classify_release_pods "${release}" "${namespace}")"; then
    emit_evidence "${scenario}" "FAIL" "install failed but release pods could not be inspected"
  elif jq -e '.unrelated == 0 and .app_failed > 0' >/dev/null <<<"${pod_summary}"; then
    emit_evidence "${scenario}" "PASS" "known-wrong database left started workloads unready while the baseline became ready" \
      "${pod_summary}"
  else
    emit_evidence "${scenario}" "FAIL" "install failed for a reason not attributable to the wrong database" \
      "${pod_summary}"
  fi
}

scenario_product_behaviors() {
  local scenario action
  local pairs=(
    "dedicated-role-denial:dedicated-role-denial"
    "two-agent-ping-reply:two-agent-ping-reply"
    "desktop-origin-bootstrap:desktop-bootstrap"
    "session-ingest-read-back:session-ingest-readback"
    "duplicate-receipt-idempotency:duplicate-receipt"
    "cross-workspace-denial:cross-workspace-denial"
  )

  for pair in "${pairs[@]}"; do
    scenario="${pair%%:*}"
    action="${pair#*:}"
    if require_apply "${scenario}" && require_isolated_release "${scenario}"; then
      adapter_scenario "${scenario}" "${action}"
    fi
  done
}

scenario_db_outage() {
  local scenario="db-outage-readiness"
  require_apply "${scenario}" || return
  require_isolated_release "${scenario}" || return
  if ! validate_hook "${DB_OUTAGE_HOOK}"; then
    emit_evidence "${scenario}" "SKIP" "executable DB outage hook is not configured"
    return
  fi

  # Mark the outage active before calling begin: a hook can disable the
  # database and then exit non-zero, and the exit trap must still run the
  # repeat-safe end action.
  DB_OUTAGE_ACTIVE=true
  if ! run_hook "${DB_OUTAGE_HOOK}" begin; then
    emit_evidence "${scenario}" "FAIL" "database outage hook failed to start"
    if run_hook "${DB_OUTAGE_HOOK}" end; then
      DB_OUTAGE_ACTIVE=false
    fi
    return
  fi

  # Only PostgreSQL-dependent workloads are expected to fail readiness. The
  # dashboard and SQLite-backed services stay ready, and completed migration
  # Job pods never become ready, so both are excluded.
  local selector="${DB_DEPENDENT_SELECTOR:-app.kubernetes.io/instance=${ACTIVE_RELEASE},app.kubernetes.io/component in (api,history)}"
  selector="${selector},!job-name"

  local stayed_ready=false
  if ! run_quiet safe_kubectl wait --for=condition=Ready=false pod \
    --namespace "${ACTIVE_NAMESPACE}" \
    --selector "${selector}" --timeout=30s; then
    stayed_ready=true
  fi

  if ! run_hook "${DB_OUTAGE_HOOK}" end; then
    emit_evidence "${scenario}" "FAIL" "database recovery hook failed"
    return
  fi
  DB_OUTAGE_ACTIVE=false

  if [[ "${stayed_ready}" == true ]]; then
    emit_evidence "${scenario}" "FAIL" "pods remained ready during database outage"
  elif run_quiet safe_kubectl wait --for=condition=Ready pod \
    --namespace "${ACTIVE_NAMESPACE}" \
    --selector "${selector}" --timeout="${TIMEOUT}"; then
    emit_evidence "${scenario}" "PASS" "readiness failed closed and recovered after database restoration"
  else
    emit_evidence "${scenario}" "FAIL" "readiness did not recover after database restoration"
  fi
}

scenario_restart_outbox() {
  local scenario="restart-outbox-recovery"
  require_apply "${scenario}" || return
  require_isolated_release "${scenario}" || return
  if [[ -z "${CONFORMANCE_ADAPTER}" ]]; then
    emit_evidence "${scenario}" "SKIP" "CONFORMANCE_ADAPTER is not configured"
    return
  fi

  if ! run_adapter outbox-enqueue; then
    emit_evidence "${scenario}" "FAIL" "could not enqueue outbox fixture"
  elif ! run_quiet safe_kubectl rollout restart deployment \
    --namespace "${ACTIVE_NAMESPACE}" \
    --selector "app.kubernetes.io/instance=${ACTIVE_RELEASE}"; then
    emit_evidence "${scenario}" "FAIL" "deployment restart failed"
  elif ! run_quiet safe_kubectl rollout status deployment \
    --namespace "${ACTIVE_NAMESPACE}" \
    --selector "app.kubernetes.io/instance=${ACTIVE_RELEASE}" --timeout="${TIMEOUT}"; then
    emit_evidence "${scenario}" "FAIL" "deployment did not recover"
  elif run_adapter outbox-recover; then
    emit_evidence "${scenario}" "PASS" "outbox item survived restart and was delivered once"
  else
    emit_evidence "${scenario}" "FAIL" "outbox recovery assertion failed"
  fi
}

# Print a JSON summary of GKE Ingress backend health as the charts deploy it:
# a GCE Ingress with a ManagedCertificate, health checks derived from
# readiness probes (a FrontendConfig, if attached, is not checked; no
# BackendConfig or HealthCheckPolicy).
gke_backend_health_summary() {
  local namespace="$1"
  local ingresses_json="" certificates_json=""
  ingresses_json="$(safe_kubectl get ingresses.networking.k8s.io \
    --namespace "${namespace}" --output json 2>/dev/null)" || return 1
  certificates_json="$(safe_kubectl get managedcertificates.networking.gke.io \
    --namespace "${namespace}" --output json 2>/dev/null)" || certificates_json='{"items":[]}'
  jq -cen --argjson ingresses "${ingresses_json}" --argjson certificates "${certificates_json}" '
    def annotations: (.metadata.annotations // {});
    [ ($ingresses.items // [])[]
      | select(
          (annotations["kubernetes.io/ingress.class"] // "") == "gce"
          or (.spec.ingressClassName // "") == "gce"
          or (annotations | has("networking.gke.io/managed-certificates"))
        )
    ] as $gke
    | [ $gke[]
        | (annotations["ingress.kubernetes.io/backends"] // "{}")
        | (try fromjson catch {})
        | to_entries[]
      ] as $backends
    | [ $gke[]
        | (annotations["networking.gke.io/managed-certificates"] // "")
        | split(",")[]
        | gsub("^\\s+|\\s+$"; "")
        | select(length > 0)
      ] | unique as $cert_names
    | ($certificates.items // []) as $certs
    | {
        gke_ingresses: ($gke | length),
        ingresses_without_backend_status: [
          $gke[] | select(((annotations["ingress.kubernetes.io/backends"] // "{}")
            | (try fromjson catch {}) | length) == 0)
        ] | length,
        backends: ($backends | length),
        unhealthy_backends: [$backends[] | select(.value != "HEALTHY")] | length,
        managed_certificates: ($cert_names | length),
        inactive_managed_certificates: [
          $cert_names[] as $name
          | select(([ $certs[] | select(.metadata.name == $name
              and (.status.certificateStatus // "") == "Active") ] | length) == 0)
        ] | length
      }
  '
}

scenario_networking() {
  local scenario="networkpolicy-gke-backend-health"
  local network_policy=false
  local backend_health=false
  local resource_names=""
  local health_summary='{}'

  if [[ "${MODE}" == "apply" ]]; then
    require_isolated_release "${scenario}" || return
  fi

  if resource_names="$(safe_kubectl get networkpolicy \
    --namespace "${ACTIVE_NAMESPACE}" --output=name 2>/dev/null)" &&
    [[ -n "${resource_names}" ]]; then
    network_policy=true
  fi
  if health_summary="$(gke_backend_health_summary "${ACTIVE_NAMESPACE}")" &&
    jq -e '
      .gke_ingresses > 0
      and .ingresses_without_backend_status == 0
      and .backends > 0
      and .unhealthy_backends == 0
      and .managed_certificates > 0
      and .inactive_managed_certificates == 0
    ' >/dev/null <<<"${health_summary}"; then
    backend_health=true
  else
    [[ -n "${health_summary}" ]] || health_summary='{}'
  fi
  health_summary="$(jq -c --argjson network_policy "${network_policy}" \
    '. + {network_policy: $network_policy}' <<<"${health_summary}" 2>/dev/null ||
    printf '{}')"

  if [[ "${network_policy}" == true && "${backend_health}" == true ]]; then
    if [[ "${MODE}" == "apply" && -n "${CONFORMANCE_ADAPTER}" ]]; then
      if run_adapter network-policy-probe; then
        emit_evidence "${scenario}" "PASS" "policy, healthy GKE backends, active certificate, and traffic probe passed" \
          "${health_summary}"
      else
        emit_evidence "${scenario}" "FAIL" "network policy traffic probe failed" "${health_summary}"
      fi
    else
      emit_evidence "${scenario}" "PASS" "NetworkPolicy present, GKE Ingress backends HEALTHY, ManagedCertificate Active" \
        "${health_summary}"
    fi
  else
    emit_evidence "${scenario}" "FAIL" "NetworkPolicy missing, or GKE Ingress backends or ManagedCertificate not healthy" \
      "${health_summary}"
  fi
}

scenario_dns_tls() {
  local scenario="dns-tls"
  if [[ -z "${CONFORMANCE_DNS_NAME}" || -z "${CONFORMANCE_BASE_URL}" ]]; then
    emit_evidence "${scenario}" "SKIP" "DNS name and HTTPS base URL are required"
    return
  fi
  if [[ "${CONFORMANCE_BASE_URL}" != https://* || "${CONFORMANCE_BASE_URL}" == *"?"* ]]; then
    emit_evidence "${scenario}" "FAIL" "base URL must be HTTPS and must not contain a query"
    return
  fi
  require_command curl
  if getent ahosts "${CONFORMANCE_DNS_NAME}" >/dev/null 2>&1 &&
    run_quiet curl --proto '=https' --tlsv1.2 --fail --silent --show-error \
      --output /dev/null "${CONFORMANCE_BASE_URL%/}${CONFORMANCE_HEALTH_PATH}"; then
    emit_evidence "${scenario}" "PASS" "DNS resolved and TLS health request passed"
  else
    emit_evidence "${scenario}" "FAIL" "DNS resolution or TLS health request failed"
  fi
}

scenario_backup_restore() {
  local scenario="backup"
  if require_apply "${scenario}" && require_isolated_release "${scenario}"; then
    if ! validate_hook "${BACKUP_HOOK}"; then
      emit_evidence "${scenario}" "SKIP" "executable backup hook is not configured"
    elif run_hook "${BACKUP_HOOK}" create; then
      emit_evidence "${scenario}" "PASS" "backup hook completed"
    else
      emit_evidence "${scenario}" "FAIL" "backup hook failed"
    fi
  fi

  scenario="isolated-restore"
  if require_apply "${scenario}" && require_isolated_release "${scenario}"; then
    if ! validate_hook "${RESTORE_HOOK}"; then
      emit_evidence "${scenario}" "SKIP" "executable restore hook is not configured"
    elif run_hook "${RESTORE_HOOK}" restore && run_hook "${RESTORE_HOOK}" verify; then
      emit_evidence "${scenario}" "PASS" "isolated restore and verification completed"
    else
      emit_evidence "${scenario}" "FAIL" "isolated restore or verification failed"
    fi
  fi
}

scenario_side_by_side_rollback() {
  local scenario="side-by-side-rollback"
  local namespace="${RUN_NAMESPACE}-rollback"
  local release="${RELEASE_NAME}-rollback"
  if [[ -z "${CHART}" || -z "${PREVIOUS_VERSION}" ]]; then
    emit_evidence "${scenario}" "SKIP" "chart and previous version are required"
    return
  fi
  require_apply "${scenario}" || return

  if ! create_namespace "${namespace}" ||
    ! install_release "${release}" "${namespace}" "${PREVIOUS_VERSION}"; then
    emit_evidence "${scenario}" "FAIL" "side-by-side previous-version install failed"
    return
  fi

  local old_namespace="${ACTIVE_NAMESPACE}"
  local old_release="${ACTIVE_RELEASE}"
  local old_url="${CONFORMANCE_BASE_URL}"
  ACTIVE_NAMESPACE="${namespace}"
  ACTIVE_RELEASE="${release}"
  [[ -n "${ROLLBACK_BASE_URL}" ]] && CONFORMANCE_BASE_URL="${ROLLBACK_BASE_URL}"
  export ACTIVE_NAMESPACE ACTIVE_RELEASE CONFORMANCE_BASE_URL

  if [[ -z "${CONFORMANCE_ADAPTER}" ]]; then
    emit_evidence "${scenario}" "PASS" "previous version installed side by side; smoke adapter not configured"
  elif run_adapter smoke; then
    emit_evidence "${scenario}" "PASS" "previous version installed side by side and passed smoke test"
  else
    emit_evidence "${scenario}" "FAIL" "side-by-side previous version failed smoke test"
  fi

  ACTIVE_NAMESPACE="${old_namespace}"
  ACTIVE_RELEASE="${old_release}"
  CONFORMANCE_BASE_URL="${old_url}"
  export ACTIVE_NAMESPACE ACTIVE_RELEASE CONFORMANCE_BASE_URL
}

scenario_cleanup() {
  local scenario="cleanup"
  if [[ "${MODE}" != "apply" || "${CLEANUP}" != true ]]; then
    emit_evidence "${scenario}" "SKIP" "cleanup not requested"
    return
  fi

  local namespace
  local failed=false
  for namespace in ${CREATED_NAMESPACES[@]+"${CREATED_NAMESPACES[@]}"}; do
    if [[ "${namespace}" != "${RUN_NAMESPACE}" && "${namespace}" != "${RUN_NAMESPACE}-"* ]]; then
      failed=true
      continue
    fi
    run_quiet safe_kubectl delete namespace "${namespace}" --wait=false || failed=true
  done
  if [[ "${failed}" == false ]]; then
    emit_evidence "${scenario}" "PASS" "run-created namespaces submitted for deletion"
  else
    emit_evidence "${scenario}" "FAIL" "one or more run-created namespaces were not deleted"
  fi
}

scenario_preflight
scenario_fresh_install
scenario_upgrade
scenario_migration_failure
scenario_wrong_database
scenario_product_behaviors
scenario_db_outage
scenario_restart_outbox
scenario_networking
scenario_dns_tls
scenario_backup_restore
scenario_side_by_side_rollback
scenario_cleanup
