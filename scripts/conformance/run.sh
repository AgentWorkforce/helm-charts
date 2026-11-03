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

install_release() {
  local release="$1"
  local namespace="$2"
  local version="$3"
  shift 3
  helm_values_args
  helm_version_args "${version}"
  # Migration Jobs are plain (non-hook) Jobs; --wait alone does not wait for
  # them, so a running or failed migration could otherwise report success.
  run_quiet safe_helm upgrade --install "${release}" "${CHART}" \
    --namespace "${namespace}" \
    --atomic --wait --wait-for-jobs --timeout "${TIMEOUT}" --hide-secret \
    ${HELM_VERSION_ARGS[@]+"${HELM_VERSION_ARGS[@]}"} ${HELM_VALUES_ARGS[@]+"${HELM_VALUES_ARGS[@]}"} "$@"
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

  if install_release "${release}" "${namespace}" "${CURRENT_VERSION}" \
    --values "${MIGRATION_FAILURE_VALUES}"; then
    emit_evidence "${scenario}" "FAIL" "migration unexpectedly succeeded"
  elif release_is_deployed "${release}" "${namespace}"; then
    emit_evidence "${scenario}" "PASS" "migration failed and atomic rollback retained the deployed release"
  else
    emit_evidence "${scenario}" "FAIL" "migration failed but previous release was not retained"
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

  if ! create_namespace "${namespace}"; then
    emit_evidence "${scenario}" "FAIL" "could not create isolated namespace"
  elif install_release "${release}" "${namespace}" "${CURRENT_VERSION}" \
    --values "${WRONG_DATABASE_VALUES}"; then
    emit_evidence "${scenario}" "FAIL" "release became ready with a known-wrong database"
  else
    emit_evidence "${scenario}" "PASS" "known-wrong database prevented readiness"
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

  if ! run_hook "${DB_OUTAGE_HOOK}" begin; then
    emit_evidence "${scenario}" "FAIL" "database outage hook failed to start"
    return
  fi
  DB_OUTAGE_ACTIVE=true

  local stayed_ready=false
  if ! run_quiet safe_kubectl wait --for=condition=Ready=false pod \
    --namespace "${ACTIVE_NAMESPACE}" \
    --selector "app.kubernetes.io/instance=${ACTIVE_RELEASE}" --timeout=30s; then
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
    --selector "app.kubernetes.io/instance=${ACTIVE_RELEASE}" --timeout="${TIMEOUT}"; then
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

scenario_networking() {
  local scenario="networkpolicy-gke-backend-health"
  local network_policy=false
  local backend_health=false
  local resource_names=""

  if [[ "${MODE}" == "apply" ]]; then
    require_isolated_release "${scenario}" || return
  fi

  if resource_names="$(safe_kubectl get networkpolicy \
    --namespace "${ACTIVE_NAMESPACE}" --output=name 2>/dev/null)" &&
    [[ -n "${resource_names}" ]]; then
    network_policy=true
  fi
  resource_names=""
  if resource_names="$(safe_kubectl get backendconfig.cloud.google.com \
    --namespace "${ACTIVE_NAMESPACE}" --output=name 2>/dev/null)" &&
    [[ -n "${resource_names}" ]]; then
    backend_health=true
  else
    resource_names=""
    if resource_names="$(safe_kubectl get healthcheckpolicy.networking.gke.io \
      --namespace "${ACTIVE_NAMESPACE}" --output=name 2>/dev/null)" &&
      [[ -n "${resource_names}" ]]; then
      backend_health=true
    fi
  fi

  if [[ "${network_policy}" == true && "${backend_health}" == true ]]; then
    if [[ "${MODE}" == "apply" && -n "${CONFORMANCE_ADAPTER}" ]]; then
      if run_adapter network-policy-probe; then
        emit_evidence "${scenario}" "PASS" "policy, GKE health resource, and traffic probe passed"
      else
        emit_evidence "${scenario}" "FAIL" "network policy traffic probe failed"
      fi
    else
      emit_evidence "${scenario}" "PASS" "NetworkPolicy and GKE backend health resources are readable"
    fi
  else
    emit_evidence "${scenario}" "FAIL" "required NetworkPolicy or GKE backend health resource is absent"
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
