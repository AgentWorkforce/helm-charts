#!/usr/bin/env bash

# Shared safety and evidence helpers for the umbrella-chart conformance harness.
# This file intentionally does not enable shell options; callers own their policy.

readonly CONFORMANCE_SCHEMA="agentworkforce.conformance/v1"

utc_now() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

die() {
  printf 'conformance: %s\n' "$*" >&2
  exit 2
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

json_object() {
  jq -cn "$@"
}

init_evidence() {
  : "${EVIDENCE_DIR:?EVIDENCE_DIR must be set}"
  mkdir -p "${EVIDENCE_DIR}"
  EVIDENCE_JSONL="${EVIDENCE_DIR}/evidence.jsonl"
  SUMMARY_JSON="${EVIDENCE_DIR}/summary.json"
  : >"${EVIDENCE_JSONL}"
  chmod 0700 "${EVIDENCE_DIR}"
  chmod 0600 "${EVIDENCE_JSONL}"
  export EVIDENCE_JSONL SUMMARY_JSON
}

emit_evidence() {
  local scenario="$1"
  local status="$2"
  local message="$3"
  local detail='{}'
  if (($# >= 4)) && jq -e 'type == "object"' >/dev/null 2>&1 <<<"$4"; then
    detail="$4"
  fi

  jq -cn \
    --arg schema "${CONFORMANCE_SCHEMA}" \
    --arg run_id "${RUN_ID}" \
    --arg timestamp "$(utc_now)" \
    --arg mode "${MODE}" \
    --arg scenario "${scenario}" \
    --arg status "${status}" \
    --arg message "${message}" \
    --argjson detail "${detail}" \
    '{
      schema: $schema,
      run_id: $run_id,
      timestamp: $timestamp,
      mode: $mode,
      scenario: $scenario,
      status: $status,
      message: $message,
      detail: $detail
    }' >>"${EVIDENCE_JSONL}"
}

finalize_evidence() {
  local ended_at="$1"
  jq -s \
    --arg schema "${CONFORMANCE_SCHEMA}" \
    --arg run_id "${RUN_ID}" \
    --arg started_at "${STARTED_AT}" \
    --arg ended_at "${ended_at}" \
    --arg mode "${MODE}" \
    '{
      schema: $schema,
      run_id: $run_id,
      started_at: $started_at,
      ended_at: $ended_at,
      mode: $mode,
      counts: {
        pass: (map(select(.status == "PASS")) | length),
        fail: (map(select(.status == "FAIL")) | length),
        skip: (map(select(.status == "SKIP")) | length),
        plan: (map(select(.status == "PLAN")) | length)
      },
      success: (all(.status != "FAIL")),
      scenarios: .
    }' "${EVIDENCE_JSONL}" >"${SUMMARY_JSON}"
  chmod 0600 "${SUMMARY_JSON}"
}

is_mutating_kubectl_verb() {
  case "$1" in
    apply|create|delete|edit|label|annotate|patch|replace|rollout|scale|set|taint|cordon|uncordon|drain|exec|cp|attach|run|expose)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

assert_no_secret_read() {
  local verb="${1:-}"
  shift || true
  local joined=" ${*,,} "

  # Metadata-only discovery is deliberately not supported. This stricter rule
  # makes it impossible for this harness to retrieve Kubernetes Secret payloads.
  if [[ "${verb}" =~ ^(get|list|watch|describe)$ ]] &&
    [[ "${joined}" =~ (^|[[:space:]/,])(secret|secrets)([[:space:]/,=.]|$) ]]; then
    printf 'conformance: refusing Kubernetes Secret read\n' >&2
    return 96
  fi

  if [[ "${joined}" == *".data"* || "${joined}" == *"stringdata"* ||
    "${joined}" == *"jsonpath"*".data"* ]]; then
    printf 'conformance: refusing command that may select Secret payload fields\n' >&2
    return 96
  fi
}

safe_kubectl() {
  local args=("$@")
  local verb=""
  local arg

  for arg in "${args[@]}"; do
    [[ "${arg}" == -* ]] && continue
    verb="${arg}"
    break
  done

  assert_no_secret_read "${verb}" "${args[@]}" || return $?

  if is_mutating_kubectl_verb "${verb}" && [[ "${MODE}" != "apply" ]]; then
    case " ${args[*]} " in
      *" --dry-run=client "*|*" --dry-run=server "*)
        ;;
      *)
        printf 'conformance: blocked mutating kubectl command in audit mode: %s\n' "${verb}" >&2
        return 97
        ;;
    esac
  fi

  kubectl "${args[@]}"
}

is_mutating_helm_verb() {
  case "$1" in
    install|upgrade|rollback|uninstall)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

safe_helm() {
  local args=("$@")
  local verb="${args[0]:-}"
  local joined=" ${args[*]} "

  if [[ "${verb}" == "get" || "${verb}" == "template" ]]; then
    printf 'conformance: refusing Helm rendered/release output that may contain Secret payloads\n' >&2
    return 96
  fi

  if is_mutating_helm_verb "${verb}" && [[ "${MODE}" != "apply" ]] &&
    [[ "${joined}" != *" --dry-run "* && "${joined}" != *" --dry-run="* ]]; then
    printf 'conformance: blocked mutating helm command in audit mode: %s\n' "${verb}" >&2
    return 97
  fi

  if [[ "${verb}" =~ ^(install|upgrade)$ ]] && [[ "${joined}" != *" --hide-secret "* ]]; then
    printf 'conformance: refusing helm %s without --hide-secret\n' "${verb}" >&2
    return 96
  fi

  helm "${args[@]}"
}

run_quiet() {
  local output_file
  output_file="$(mktemp "${EVIDENCE_DIR}/command.XXXXXX")"
  chmod 0600 "${output_file}"
  if "$@" >"${output_file}" 2>&1; then
    rm -f "${output_file}"
    return 0
  else
    local rc=$?
    # Command output is intentionally not persisted: tools may include
    # sensitive values in errors even when the harness requests redaction.
    rm -f "${output_file}"
    return "${rc}"
  fi
}

require_apply() {
  local scenario="$1"
  if [[ "${MODE}" != "apply" ]]; then
    emit_evidence "${scenario}" "PLAN" "requires explicit APPLY approval" \
      "$(json_object --arg namespace "${RUN_NAMESPACE}" '{namespace: $namespace}')"
    return 1
  fi
  return 0
}

run_adapter() {
  local action="$1"
  shift

  if [[ -z "${CONFORMANCE_ADAPTER:-}" ]]; then
    return 95
  fi
  [[ -x "${CONFORMANCE_ADAPTER}" ]] || return 94

  # Adapter output is discarded by design. Its exit status is the contract and
  # prevents API response bodies or credentials entering evidence.
  run_quiet env \
    CONFORMANCE_ACTION="${action}" \
    CONFORMANCE_RUN_ID="${RUN_ID}" \
    CONFORMANCE_NAMESPACE="${ACTIVE_NAMESPACE:-${RUN_NAMESPACE}}" \
    CONFORMANCE_RELEASE="${ACTIVE_RELEASE:-${RELEASE_NAME}}" \
    CONFORMANCE_BASE_URL="${CONFORMANCE_BASE_URL:-}" \
    "${CONFORMANCE_ADAPTER}" "${action}" "$@"
}

adapter_scenario() {
  local scenario="$1"
  local action="$2"
  shift 2

  if [[ -z "${CONFORMANCE_ADAPTER:-}" ]]; then
    emit_evidence "${scenario}" "SKIP" "CONFORMANCE_ADAPTER is not configured"
    return 0
  fi
  if run_adapter "${action}" "$@"; then
    emit_evidence "${scenario}" "PASS" "adapter assertion passed"
  else
    local rc=$?
    emit_evidence "${scenario}" "FAIL" "adapter assertion failed" \
      "$(json_object --argjson exit_code "${rc}" '{exit_code: $exit_code}')"
    return 1
  fi
}

validate_hook() {
  local hook="$1"
  [[ -n "${hook}" && -x "${hook}" ]]
}

run_hook() {
  local hook="$1"
  local action="$2"
  run_quiet env \
    CONFORMANCE_ACTION="${action}" \
    CONFORMANCE_RUN_ID="${RUN_ID}" \
    CONFORMANCE_NAMESPACE="${ACTIVE_NAMESPACE:-${RUN_NAMESPACE}}" \
    CONFORMANCE_RELEASE="${ACTIVE_RELEASE:-${RELEASE_NAME}}" \
    "${hook}" "${action}"
}
