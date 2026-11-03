#!/usr/bin/env bash
# Offline tests for the self-hosted operator scripts and the agent-relay
# recovery scripts. Every external command (kubectl, helm, gcloud, curl,
# openssl, timeout) is mocked; nothing contacts a cluster or cloud.
set -euo pipefail

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SELFHOST_DIR="$(cd -- "${TEST_DIR}/.." && pwd)"
REPO_ROOT="$(cd -- "${SELFHOST_DIR}/../.." && pwd)"
RECOVERY_DIR="${REPO_ROOT}/charts/agent-relay/scripts"
# Run the scripts under TEST_BASH (for example /bin/bash 3.2 on macOS).
TEST_BASH="${TEST_BASH:-bash}"
tmp_root="$(mktemp -d)"
trap 'rm -rf "${tmp_root}"' EXIT

fail() {
  printf 'not ok - %s\n' "$*" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$*"
}

mock_bin="${tmp_root}/bin"
fixtures="${tmp_root}/fixtures"
gcs="${tmp_root}/gcs"
command_log="${tmp_root}/commands.log"
mkdir -p "${mock_bin}" "${fixtures}" "${gcs}"
: >"${command_log}"

# kubectl prints ${MOCK_FIXTURES}/<resource>.json for "get <resource>".
cat >"${mock_bin}/kubectl" <<'MOCK'
#!/usr/bin/env bash
printf 'kubectl' >>"${MOCK_COMMAND_LOG}"
printf ' %s' "$@" >>"${MOCK_COMMAND_LOG}"
printf '\n' >>"${MOCK_COMMAND_LOG}"
resource=""
previous=""
for arg in "$@"; do
  [[ "${previous}" == "get" ]] && resource="${arg}"
  previous="${arg}"
done
if [[ -n "${resource}" && -f "${MOCK_FIXTURES}/${resource}.json" ]]; then
  cat "${MOCK_FIXTURES}/${resource}.json"
  exit 0
fi
case " $* " in
  *" api-resources "*)
    [[ -f "${MOCK_FIXTURES}/api-resources.txt" ]] && cat "${MOCK_FIXTURES}/api-resources.txt"
    exit 0
    ;;
  *" get "*) printf '{"items":[]}\n' ;;
esac
exit 0
MOCK

cat >"${mock_bin}/helm" <<'MOCK'
#!/usr/bin/env bash
printf 'helm' >>"${MOCK_COMMAND_LOG}"
printf ' %s' "$@" >>"${MOCK_COMMAND_LOG}"
printf '\n' >>"${MOCK_COMMAND_LOG}"
case " $* " in
  *" status "*)
    if [[ -f "${MOCK_FIXTURES}/helm-status.json" ]]; then
      cat "${MOCK_FIXTURES}/helm-status.json"
    else
      printf '{"name":"relay","version":3,"info":{"status":"deployed"},"chart":{"metadata":{"version":"1.0.0"}}}\n'
    fi
    ;;
  *" show chart "*) printf 'name: agent-relay\nversion: 2.0.0\n' ;;
esac
exit 0
MOCK

cat >"${mock_bin}/curl" <<'MOCK'
#!/usr/bin/env bash
printf 'curl %s\n' "${@: -1}" >>"${MOCK_COMMAND_LOG}"
printf '200'
MOCK

cat >"${mock_bin}/timeout" <<'MOCK'
#!/usr/bin/env bash
shift
exec "$@"
MOCK

cat >"${mock_bin}/openssl" <<'MOCK'
#!/usr/bin/env bash
if [[ "$1" == "s_client" ]]; then
  previous=""
  for arg in "$@"; do
    [[ "${previous}" == "-servername" ]] && printf 'openssl-servername %s\n' "${arg}" >>"${MOCK_COMMAND_LOG}"
    previous="${arg}"
  done
  printf 'CERT\n'
  exit 0
fi
cat >/dev/null
exit 0
MOCK

# gcloud storage backed by a local directory. "cp" honours
# --if-generation-match=0 (create-only) and "ls" supports one-level globs.
cat >"${mock_bin}/gcloud" <<'MOCK'
#!/usr/bin/env bash
printf 'gcloud' >>"${MOCK_COMMAND_LOG}"
printf ' %s' "$@" >>"${MOCK_COMMAND_LOG}"
printf '\n' >>"${MOCK_COMMAND_LOG}"
to_path() { printf '%s/%s' "${MOCK_GCS}" "${1#gs://}"; }
[[ "$1" == "storage" ]] || exit 0
shift
case "$1" in
  cp)
    shift
    create_only=false
    args=()
    for arg in "$@"; do
      case "${arg}" in
        --if-generation-match=0) create_only=true ;;
        -*) ;;
        *) args+=("${arg}") ;;
      esac
    done
    src="${args[0]}"
    dst="${args[1]}"
    [[ "${src}" == gs://* ]] && src="$(to_path "${src}")"
    if [[ "${dst}" == gs://* ]]; then
      dst="$(to_path "${dst}")"
      if [[ "${create_only}" == true && -e "${dst}" ]]; then
        echo "precondition failed" >&2
        exit 1
      fi
      mkdir -p "$(dirname "${dst}")"
    fi
    cp "${src}" "${dst}"
    ;;
  ls)
    shift
    pattern="$(to_path "${1%/\*\*}")"
    found=false
    for match in ${pattern}; do
      [[ -e "${match}" ]] || continue
      found=true
      printf 'gs://%s\n' "${match#"${MOCK_GCS}"/}"
    done
    [[ "${found}" == true ]]
    ;;
  *) exit 0 ;;
esac
MOCK
chmod +x "${mock_bin}"/*

export PATH="${mock_bin}:${PATH}"
export MOCK_COMMAND_LOG="${command_log}"
export MOCK_FIXTURES="${fixtures}"
export MOCK_GCS="${gcs}"

scripts=(
  "${SELFHOST_DIR}/verify-agent-relay.sh"
  "${SELFHOST_DIR}/pre-upgrade-check.sh"
  "${SELFHOST_DIR}/record-restore-drill.sh"
  "${RECOVERY_DIR}/gcp-recovery-backup.sh"
  "${RECOVERY_DIR}/gcp-restore-drill-request.sh"
  "${RECOVERY_DIR}/gcp-restore-drill-audit.sh"
)
for script in "${scripts[@]}"; do
  "${TEST_BASH}" -n "${script}"
done
pass "shell syntax"
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck -x -S warning "${scripts[@]}" "${BASH_SOURCE[0]}"
  pass "shellcheck"
fi

reset_fixtures() {
  rm -rf "${fixtures}" "${gcs}"
  mkdir -p "${fixtures}" "${gcs}"
  : >"${command_log}"
}

# ---------------------------------------------------------------------------
# verify-agent-relay.sh
# ---------------------------------------------------------------------------
write_verify_fixtures() {
  local certificate_status="${1:-Active}"
  cat >"${fixtures}/jobs.batch.json" <<'JSON'
{"items":[{"metadata":{"name":"relay-cloud-api-migrate-1"},
  "status":{"succeeded":1,"conditions":[{"type":"Complete","status":"True"}]}}]}
JSON
  cat >"${fixtures}/deployments.apps,statefulsets.apps,daemonsets.apps.json" <<'JSON'
{"items":[{"kind":"Deployment","metadata":{"generation":1},"spec":{"replicas":1},
  "status":{"observedGeneration":1,"availableReplicas":1,"updatedReplicas":1}}]}
JSON
  cat >"${fixtures}/pods.json" <<'JSON'
{"items":[{"metadata":{},"status":{"phase":"Running","containerStatuses":[{"ready":true}]}}]}
JSON
  # The GKE Ingress as charts/agent-relay renders it: no spec.tls, TLS via
  # the networking.gke.io/managed-certificates annotation.
  cat >"${fixtures}/ingresses.networking.k8s.io.json" <<'JSON'
{"items":[{"metadata":{"name":"agent-relay","annotations":{
    "kubernetes.io/ingress.class":"gce",
    "networking.gke.io/managed-certificates":"agent-relay-cert"}},
  "spec":{"rules":[{"host":"relay.example.com"},{"host":"api.example.com"},
    {"host":"cast.example.com"},{"host":"history.example.com"}]},
  "status":{"loadBalancer":{"ingress":[{"ip":"192.0.2.10"}]}}}]}
JSON
  jq -n --arg status "${certificate_status}" '{items: [{
    metadata: {name: "agent-relay-cert"},
    spec: {domains: ["relay.example.com", "api.example.com", "cast.example.com", "history.example.com"]},
    status: {certificateStatus: $status}}]}' \
    >"${fixtures}/managedcertificates.networking.gke.io.json"
}

run_verify() {
  local output="$1"
  shift
  set +e
  "${TEST_BASH}" "${SELFHOST_DIR}/verify-agent-relay.sh" \
    --namespace relay --release relay "$@" >"${output}" 2>&1
  local rc=$?
  set -e
  return "${rc}"
}

reset_fixtures
write_verify_fixtures
run_verify "${tmp_root}/verify-gke.out" ||
  { cat "${tmp_root}/verify-gke.out" >&2; fail "verify failed for a GKE managed-certificate Ingress"; }
grep -q '^PROOF|PASS|managed_certificate|' "${tmp_root}/verify-gke.out" ||
  fail "ManagedCertificate status was not checked"
for host in relay.example.com api.example.com cast.example.com history.example.com; do
  grep -q "^openssl-servername ${host}$" "${command_log}" ||
    fail "TLS host ${host} was not derived from the managed certificate"
done
pass "verify derives TLS hosts from the GKE managed-certificate annotation"

reset_fixtures
write_verify_fixtures Provisioning
if run_verify "${tmp_root}/verify-provisioning.out"; then
  fail "verify passed with a ManagedCertificate that is not Active"
fi
grep -q '^PROOF|FAIL|managed_certificate|.*inactive=1' "${tmp_root}/verify-provisioning.out" ||
  fail "inactive ManagedCertificate was not reported"
pass "verify requires the ManagedCertificate to be Active"

reset_fixtures
write_verify_fixtures
run_verify "${tmp_root}/verify-host.out" --ingress-host api.example.com ||
  { cat "${tmp_root}/verify-host.out" >&2; fail "verify failed with --ingress-host"; }
[[ "$(grep -c '^curl ' "${command_log}")" -eq 1 ]] &&
  grep -q '^curl https://api.example.com/health$' "${command_log}" ||
  fail "--ingress-host did not limit derived health URLs to the requested host"
[[ "$(grep -c '^openssl-servername ' "${command_log}")" -eq 1 ]] &&
  grep -q '^openssl-servername api.example.com$' "${command_log}" ||
  fail "--ingress-host did not limit TLS hosts to the requested host"

# With spec.tls and cert-manager, only the requested host's Secret reference
# is corroborated; an unready sibling certificate must not fail the check.
reset_fixtures
write_verify_fixtures
jq '.items[0].metadata.annotations = {} | .items[0].spec.tls = [
  {hosts: ["api.example.com"], secretName: "api-tls"},
  {hosts: ["cast.example.com"], secretName: "cast-tls"}]' \
  "${fixtures}/ingresses.networking.k8s.io.json" >"${fixtures}/ingress.tmp"
mv "${fixtures}/ingress.tmp" "${fixtures}/ingresses.networking.k8s.io.json"
printf 'certificates.cert-manager.io\n' >"${fixtures}/api-resources.txt"
cat >"${fixtures}/certificates.cert-manager.io.json" <<'JSON'
{"items":[
  {"spec":{"secretName":"api-tls"},"status":{"conditions":[{"type":"Ready","status":"True"}]}},
  {"spec":{"secretName":"cast-tls"},"status":{"conditions":[{"type":"Ready","status":"False"}]}}]}
JSON
run_verify "${tmp_root}/verify-refs.out" --ingress-host api.example.com ||
  { cat "${tmp_root}/verify-refs.out" >&2; fail "sibling host certificate failed --ingress-host verification"; }
grep -q '^PROOF|PASS|cert_manager|certificates=1 ready=1' "${tmp_root}/verify-refs.out" ||
  fail "cert-manager references were not narrowed to the requested host"
if run_verify "${tmp_root}/verify-refs-all.out"; then
  fail "unready certificate was ignored without --ingress-host"
fi
pass "verify narrows health, TLS, and certificate references to --ingress-host"

printf 'All self-hosted script tests passed.\n'
