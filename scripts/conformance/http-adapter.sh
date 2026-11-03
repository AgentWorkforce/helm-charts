#!/usr/bin/env bash
set -euo pipefail

# Reference adapter for an application-provided conformance API. The API owns
# fixture creation and semantic assertions; this adapter only accepts an
# explicit success envelope and never prints a response body.

action="${1:-${CONFORMANCE_ACTION:-}}"
base_url="${CONFORMANCE_BASE_URL:-}"
api_prefix="${CONFORMANCE_API_PREFIX:-/api/conformance/v1}"
curl_config="${CONFORMANCE_CURL_CONFIG:-}"

[[ -n "${action}" ]] || {
  printf 'http-adapter: action is required\n' >&2
  exit 64
}
[[ "${base_url}" == https://* && "${base_url}" != *"?"* ]] || {
  printf 'http-adapter: CONFORMANCE_BASE_URL must be HTTPS without a query\n' >&2
  exit 64
}
command -v curl >/dev/null 2>&1 || exit 69
command -v jq >/dev/null 2>&1 || exit 69

case "${action}" in
  dedicated-role-denial|two-agent-ping-reply|desktop-bootstrap|\
session-ingest-readback|duplicate-receipt|cross-workspace-denial|\
outbox-enqueue|outbox-recover|network-policy-probe|smoke)
    ;;
  *)
    printf 'http-adapter: unsupported action: %s\n' "${action}" >&2
    exit 64
    ;;
esac

response_file="$(mktemp)"
request_file="$(mktemp)"
cleanup() {
  rm -f "${response_file}" "${request_file}"
}
trap cleanup EXIT
chmod 0600 "${response_file}" "${request_file}"

jq -cn \
  --arg action "${action}" \
  --arg run_id "${CONFORMANCE_RUN_ID:?CONFORMANCE_RUN_ID is required}" \
  --arg namespace "${CONFORMANCE_NAMESPACE:-}" \
  --arg release "${CONFORMANCE_RELEASE:-}" \
  '{
    action: $action,
    run_id: $run_id,
    target: {
      namespace: $namespace,
      release: $release
    }
  }' >"${request_file}"

curl_args=(
  --proto '=https'
  --tlsv1.2
  --fail-with-body
  --silent
  --show-error
  --request POST
  --header 'Content-Type: application/json'
  --data-binary "@${request_file}"
  --output "${response_file}"
)
if [[ -n "${curl_config}" ]]; then
  [[ -f "${curl_config}" ]] || exit 66
  curl_args=(--config "${curl_config}" "${curl_args[@]}")
fi

curl "${curl_args[@]}" "${base_url%/}${api_prefix}/${action}" >/dev/null
jq -e --arg action "${action}" \
  '.ok == true and .action == $action' "${response_file}" >/dev/null
