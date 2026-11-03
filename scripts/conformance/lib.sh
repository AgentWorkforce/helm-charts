#!/usr/bin/env bash
# jq programs are intentionally single-quoted.
# shellcheck disable=SC2016

# Shared safety and evidence helpers for the umbrella-chart conformance harness.
# This file intentionally does not enable shell options; callers own their policy.
# It must stay compatible with bash 3.2 (macOS /bin/bash).

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

# Global options that take a separate value and may appear before the verb.
# Anything else that looks like an option before the verb is rejected so a
# value can never be mistaken for the verb.
kubectl_global_option_takes_value() {
  case "$1" in
    -n|--namespace|--context|--cluster|--user|--kubeconfig|-s|--server|\
--as|--as-group|--as-uid|--request-timeout|--cache-dir|\
--certificate-authority|--client-certificate|--client-key|\
--tls-server-name|--token|--profile|--profile-output|-v|--v|--vmodule|\
--log-file|--log-file-max-size|--log-flush-frequency)
      return 0
      ;;
  esac
  return 1
}

kubectl_global_option_is_flag() {
  case "$1" in
    --insecure-skip-tls-verify|--insecure-skip-tls-verify=*|\
--match-server-version|--match-server-version=*|\
--warnings-as-errors|--warnings-as-errors=*|\
--disable-compression|--disable-compression=*)
      return 0
      ;;
  esac
  return 1
}

helm_global_option_takes_value() {
  case "$1" in
    -n|--namespace|--kube-context|--kubeconfig|--kube-apiserver|\
--kube-as-user|--kube-as-group|--kube-ca-file|--kube-token|\
--kube-tls-server-name|--registry-config|--repository-cache|\
--repository-config|--burst-limit|--qps|--content-cache)
      return 0
      ;;
  esac
  return 1
}

helm_global_option_is_flag() {
  case "$1" in
    --debug|--debug=*|--kube-insecure-skip-tls-verify|--kube-insecure-skip-tls-verify=*)
      return 0
      ;;
  esac
  return 1
}

# Print the first one or two positional words (verb and optional subverb)
# after skipping known global options. Returns 98 when an unknown option or a
# missing option value precedes the verb.
# Usage: parse_command_words kubectl|helm ARGS...
parse_command_words() {
  local tool="$1"
  shift
  local words=""
  local count=0
  local expecting_value=false
  local verb_seen=false
  local arg

  for arg in "$@"; do
    if [[ "${expecting_value}" == true ]]; then
      expecting_value=false
      continue
    fi
    if [[ "${verb_seen}" == false && "${arg}" == -* ]]; then
      if [[ "${arg}" == --*=* ]] && "${tool}_global_option_takes_value" "${arg%%=*}"; then
        continue
      fi
      if "${tool}_global_option_takes_value" "${arg}"; then
        expecting_value=true
        continue
      fi
      if "${tool}_global_option_is_flag" "${arg}"; then
        continue
      fi
      return 98
    fi
    if [[ "${verb_seen}" == true && "${arg}" == -* ]]; then
      # Options after the verb end the search for a subverb.
      break
    fi
    verb_seen=true
    words="${words}${words:+ }${arg}"
    count=$((count + 1))
    ((count >= 2)) && break
  done

  [[ "${expecting_value}" == false && -n "${words}" ]] || return 98
  printf '%s\n' "${words}"
}

# Read-only kubectl commands permitted in every mode. Everything not listed
# here or in kubectl_mutation_class is denied (default deny).
kubectl_is_read_only() {
  local verb="$1"
  local subverb="${2:-}"
  case "${verb}" in
    get|describe|version|wait|api-resources|api-versions|explain|top)
      return 0
      ;;
    rollout)
      [[ "${subverb}" == "status" || "${subverb}" == "history" ]]
      return
      ;;
    auth)
      [[ "${subverb}" == "can-i" ]]
      return
      ;;
  esac
  return 1
}

kubectl_is_mutating() {
  case "$1" in
    apply|create|delete|edit|label|annotate|patch|replace|rollout|scale|set|\
taint|cordon|uncordon|drain|exec|cp|attach|run|expose|autoscale)
      return 0
      ;;
  esac
  return 1
}

# Kept for callers that only need the classification.
is_mutating_kubectl_verb() {
  kubectl_is_mutating "$1"
}

kubectl_supports_dry_run() {
  case "$1" in
    apply|create|delete|patch|replace|label|annotate|expose|run|set|scale|autoscale)
      return 0
      ;;
  esac
  return 1
}

assert_no_secret_read() {
  local verb="${1:-}"
  shift || true
  local joined
  joined=" $(printf '%s ' "$@" | tr '[:upper:]' '[:lower:]')"

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
  local words verb subverb
  if ! words="$(parse_command_words kubectl "$@")"; then
    printf 'conformance: refusing kubectl command with unrecognized options before the verb\n' >&2
    return 98
  fi
  verb="${words%% *}"
  subverb=""
  [[ "${words}" == *" "* ]] && subverb="${words#* }"

  assert_no_secret_read "${verb}" "$@" || return $?

  if kubectl_is_read_only "${verb}" "${subverb}"; then
    :
  elif kubectl_is_mutating "${verb}"; then
    if [[ "${MODE}" != "apply" ]]; then
      case " $* " in
        *" --dry-run=client "*|*" --dry-run=server "*)
          kubectl_supports_dry_run "${verb}" || {
            printf 'conformance: blocked mutating kubectl command in audit mode: %s\n' "${verb}" >&2
            return 97
          }
          ;;
        *)
          printf 'conformance: blocked mutating kubectl command in audit mode: %s\n' "${verb}" >&2
          return 97
          ;;
      esac
    fi
  else
    printf 'conformance: kubectl verb is not on the allowlist: %s\n' "${verb}" >&2
    return 97
  fi

  kubectl "$@"
}

helm_is_read_only() {
  case "$1" in
    version|list|ls|status|history|show|search|env|lint)
      return 0
      ;;
  esac
  return 1
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
  local words verb
  local joined=" $* "
  if ! words="$(parse_command_words helm "$@")"; then
    printf 'conformance: refusing helm command with unrecognized options before the verb\n' >&2
    return 98
  fi
  verb="${words%% *}"

  if [[ "${verb}" == "get" || "${verb}" == "template" ]]; then
    printf 'conformance: refusing Helm rendered/release output that may contain Secret payloads\n' >&2
    return 96
  fi

  if helm_is_read_only "${verb}"; then
    :
  elif is_mutating_helm_verb "${verb}"; then
    if [[ "${MODE}" != "apply" ]] &&
      ! [[ "${verb}" =~ ^(install|upgrade)$ &&
        ( "${joined}" == *" --dry-run "* || "${joined}" == *" --dry-run="* ) ]]; then
      printf 'conformance: blocked mutating helm command in audit mode: %s\n' "${verb}" >&2
      return 97
    fi
  else
    printf 'conformance: helm verb is not on the allowlist: %s\n' "${verb}" >&2
    return 97
  fi

  if [[ "${verb}" =~ ^(install|upgrade)$ ]] && [[ "${joined}" != *" --hide-secret "* ]]; then
    printf 'conformance: refusing helm %s without --hide-secret\n' "${verb}" >&2
    return 96
  fi

  helm "$@"
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
