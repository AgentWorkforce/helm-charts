#!/usr/bin/env bash
set -euo pipefail

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFORMANCE_DIR="$(cd -- "${TEST_DIR}/.." && pwd)"
HARNESS="${CONFORMANCE_DIR}/run.sh"
LIB="${CONFORMANCE_DIR}/lib.sh"
tmp_root="$(mktemp -d)"
trap 'rm -rf "${tmp_root}"' EXIT

fail() {
  printf 'not ok - %s\n' "$*" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$*"
}

assert_contains() {
  local file="$1"
  local pattern="$2"
  rg -q -- "${pattern}" "${file}" || fail "${file} does not contain ${pattern}"
}

assert_not_contains() {
  local file="$1"
  local pattern="$2"
  if rg -q -- "${pattern}" "${file}"; then
    fail "${file} unexpectedly contains ${pattern}"
  fi
}

mock_bin="${tmp_root}/bin"
mkdir -p "${mock_bin}"
command_log="${tmp_root}/commands.log"
: >"${command_log}"

cat >"${mock_bin}/helm" <<'MOCK'
#!/usr/bin/env bash
printf 'helm' >>"${MOCK_COMMAND_LOG}"
printf ' %q' "$@" >>"${MOCK_COMMAND_LOG}"
printf '\n' >>"${MOCK_COMMAND_LOG}"
case " $* " in
  *migration-failure.yaml*|*wrong-database.yaml*)
    exit 1
    ;;
  *" list "*)
    printf '[{"name":"aw-conformance-test-migration","status":"deployed"}]\n'
    ;;
esac
exit 0
MOCK

cat >"${mock_bin}/kubectl" <<'MOCK'
#!/usr/bin/env bash
printf 'kubectl' >>"${MOCK_COMMAND_LOG}"
printf ' %q' "$@" >>"${MOCK_COMMAND_LOG}"
printf '\n' >>"${MOCK_COMMAND_LOG}"
case " $* " in
  *" get networkpolicy "*) printf 'networkpolicy.networking.k8s.io/default-deny\n' ;;
  *" get backendconfig.cloud.google.com "*) printf 'backendconfig.cloud.google.com/service\n' ;;
esac
exit 0
MOCK

cat >"${mock_bin}/curl" <<'MOCK'
#!/usr/bin/env bash
output_file=""
action=""
while (($#)); do
  case "$1" in
    --output) output_file="$2"; shift 2 ;;
    https://*) action="${1##*/}"; shift ;;
    *) shift ;;
  esac
done
if [[ -n "${output_file}" ]]; then
  printf '{"ok":true,"action":"%s"}\n' "${action}" >"${output_file}"
fi
exit 0
MOCK

cat >"${mock_bin}/getent" <<'MOCK'
#!/usr/bin/env bash
printf '192.0.2.10 STREAM conformance.example.test\n'
MOCK
chmod +x "${mock_bin}/helm" "${mock_bin}/kubectl" "${mock_bin}/curl" "${mock_bin}/getent"

export PATH="${mock_bin}:${PATH}"
export MOCK_COMMAND_LOG="${command_log}"

bash -n "${HARNESS}" "${LIB}" "${CONFORMANCE_DIR}/http-adapter.sh"
pass "shell syntax"

if command -v shellcheck >/dev/null 2>&1; then
  shellcheck "${HARNESS}" "${LIB}" "${CONFORMANCE_DIR}/http-adapter.sh"
  pass "shellcheck"
fi

CONFORMANCE_BASE_URL=https://conformance.example.test \
  CONFORMANCE_RUN_ID=adapter-test \
  "${CONFORMANCE_DIR}/http-adapter.sh" smoke
if CONFORMANCE_BASE_URL=http://conformance.example.test \
  CONFORMANCE_RUN_ID=adapter-test \
  "${CONFORMANCE_DIR}/http-adapter.sh" smoke >/dev/null 2>&1; then
  fail "HTTP adapter accepted a non-TLS URL"
fi
pass "reference HTTP adapter validates TLS and success envelopes"

audit_evidence="${tmp_root}/audit-evidence"
"${HARNESS}" \
  --chart ./umbrella \
  --target-namespace production \
  --target-release agentworkforce \
  --evidence-dir "${audit_evidence}" >/dev/null

assert_contains "${command_log}" 'helm upgrade --install'
assert_contains "${command_log}" '--dry-run'
assert_contains "${command_log}" '--hide-secret'
assert_not_contains "${command_log}" 'kubectl (apply|create|delete|edit|label|annotate|patch|replace|rollout|scale|set|exec|run)'
jq -e '.success == true and .mode == "audit"' "${audit_evidence}/summary.json" >/dev/null
jq -e '.scenarios | length == 19' "${audit_evidence}/summary.json" >/dev/null
jq -e '.scenarios[] | select(.scenario == "fresh-install" and .status == "PASS")' \
  "${audit_evidence}/summary.json" >/dev/null
pass "audit mode is dry-run/read-only and emits valid evidence"

: >"${command_log}"
if "${HARNESS}" --apply --approval NOPE --chart ./umbrella \
  --evidence-dir "${tmp_root}/rejected" >/dev/null 2>&1; then
  fail "invalid apply approval was accepted"
fi
[[ ! -s "${command_log}" ]] || fail "commands ran before apply approval was rejected"
pass "apply requires literal APPLY approval"

: >"${command_log}"
apply_evidence="${tmp_root}/apply-evidence"
adapter="${tmp_root}/adapter"
hook="${tmp_root}/hook"
migration_values="${tmp_root}/migration-failure.yaml"
wrong_database_values="${tmp_root}/wrong-database.yaml"
: >"${migration_values}"
: >"${wrong_database_values}"
cat >"${adapter}" <<'MOCK'
#!/usr/bin/env bash
printf 'adapter %s\n' "$1" >>"${MOCK_COMMAND_LOG}"
exit 0
MOCK
cat >"${hook}" <<'MOCK'
#!/usr/bin/env bash
printf 'hook %s\n' "$1" >>"${MOCK_COMMAND_LOG}"
exit 0
MOCK
chmod +x "${adapter}" "${hook}"

if ! "${HARNESS}" \
  --apply --approval APPLY --cleanup \
  --chart ./umbrella \
  --current-version 2.0.0 \
  --previous-version 1.0.0 \
  --namespace aw-conformance-test \
  --release aw-conformance-test \
  --migration-failure-values "${migration_values}" \
  --wrong-database-values "${wrong_database_values}" \
  --adapter "${adapter}" \
  --base-url https://conformance.example.test \
  --dns-name conformance.example.test \
  --db-outage-hook "${hook}" \
  --backup-hook "${hook}" \
  --restore-hook "${hook}" \
  --rollback-base-url https://rollback.example.test \
  --evidence-dir "${apply_evidence}" >/dev/null; then
  jq . "${apply_evidence}/summary.json" >&2
  fail "full mocked apply run failed"
fi

assert_contains "${command_log}" 'kubectl create namespace aw-conformance-test'
assert_contains "${command_log}" 'helm upgrade --install aw-conformance-test'
assert_contains "${command_log}" '--hide-secret'
assert_contains "${command_log}" 'kubectl delete namespace aw-conformance-test'
jq -e '
  .success == true
  and .mode == "apply"
  and (.scenarios | length == 19)
  and (.counts.pass == 19)
  and (.counts.fail == 0)
  and (.counts.skip == 0)
  and (.counts.plan == 0)
' "${apply_evidence}/summary.json" >/dev/null
pass "approved apply mode exercises all scenarios with isolated mocks"

: >"${command_log}"
set +e
(
  # shellcheck source=../lib.sh
  source "${LIB}"
  MODE=audit
  safe_kubectl get secrets --namespace production --output=yaml
) >/dev/null 2>&1
secret_rc=$?
set -e
[[ "${secret_rc}" -eq 96 ]] || fail "Secret read was not rejected with safety code"
[[ ! -s "${command_log}" ]] || fail "blocked Secret read reached kubectl"
pass "Kubernetes Secret reads are blocked before execution"

: >"${command_log}"
set +e
(
  # shellcheck source=../lib.sh
  source "${LIB}"
  MODE=apply
  safe_helm upgrade release ./chart
) >/dev/null 2>&1
helm_rc=$?
set -e
[[ "${helm_rc}" -eq 96 ]] || fail "Helm output without --hide-secret was not rejected"
[[ ! -s "${command_log}" ]] || fail "unsafe Helm command reached helm"
pass "Helm install/upgrade requires Secret redaction"

printf 'All conformance harness tests passed.\n'
