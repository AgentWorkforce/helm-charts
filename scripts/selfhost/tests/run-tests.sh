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

# kubectl prints ${MOCK_FIXTURES}/<resource>-<name>.json or
# ${MOCK_FIXTURES}/<resource>.json for "get <resource> [name]". "create -f"
# records the created object's name and rejects duplicates.
cat >"${mock_bin}/kubectl" <<'MOCK'
#!/usr/bin/env bash
printf 'kubectl' >>"${MOCK_COMMAND_LOG}"
printf ' %s' "$@" >>"${MOCK_COMMAND_LOG}"
printf '\n' >>"${MOCK_COMMAND_LOG}"
resource=""
name=""
create_file=""
previous=""
for arg in "$@"; do
  if [[ "${previous}" == "get" ]]; then
    resource="${arg}"
  elif [[ -n "${resource}" && -z "${name}" && "${arg}" != -* &&
    "${previous}" != -* ]]; then
    name="${arg}"
  fi
  [[ "${previous}" == "create" && "${arg}" == "-f" ]] && create_file="next"
  [[ "${create_file}" == "next" && "${arg}" != "-f" ]] && create_file="${arg}"
  previous="${arg}"
done
if [[ -n "${create_file}" && "${create_file}" != "next" ]]; then
  created="$(jq -r '.metadata.name' "${create_file}")"
  if grep -qx "created ${created}" "${MOCK_COMMAND_LOG}"; then
    echo "AlreadyExists" >&2
    exit 1
  fi
  printf 'created %s\n' "${created}" >>"${MOCK_COMMAND_LOG}"
  exit 0
fi
if [[ -n "${resource}" ]]; then
  for fixture in "${MOCK_FIXTURES}/${resource}-${name}.json" "${MOCK_FIXTURES}/${resource}.json"; do
    if [[ -f "${fixture}" ]]; then
      cat "${fixture}"
      exit 0
    fi
  done
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
    # helm-revisions, when present, supplies one revision per call.
    revision=3
    if [[ -s "${MOCK_FIXTURES}/helm-revisions" ]]; then
      revision="$(head -n 1 "${MOCK_FIXTURES}/helm-revisions")"
      tail -n +2 "${MOCK_FIXTURES}/helm-revisions" >"${MOCK_FIXTURES}/helm-revisions.next"
      mv "${MOCK_FIXTURES}/helm-revisions.next" "${MOCK_FIXTURES}/helm-revisions"
    fi
    printf '{"name":"relay","version":%s,"info":{"status":"deployed"},"chart":{"metadata":{"version":"1.0.0"}}}\n' "${revision}"
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
case "$1 $2 $3" in
  "storage buckets describe") cat "${MOCK_FIXTURES}/gcloud-bucket.json"; exit 0 ;;
  "sql instances describe") cat "${MOCK_FIXTURES}/gcloud-sql-instance.json"; exit 0 ;;
  "sql backups list")
    # Report one successful backup whose description is the filtered ID.
    for arg in "$@"; do
      case "${arg}" in --filter=description=*) id="${arg#--filter=description=}" ;; esac
    done
    printf '[{"id":"1700000000","status":"SUCCESSFUL","description":"%s"}]\n' "${id}"
    exit 0
    ;;
esac
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

# ---------------------------------------------------------------------------
# pre-upgrade-check.sh
# ---------------------------------------------------------------------------
now_utc() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

write_upgrade_evidence() {
  local dir="$1"
  local now
  now="$(now_utc)"
  mkdir -p "${dir}"
  jq -n --arg now "${now}" '{
    recoveryId: "ar-20260101T000000Z-abc123", status: "PASS",
    providerStatus: "SUCCESSFUL", sourceRelease: "relay", sourceRevision: 3,
    writesQuiesced: true, artifactsComplete: true, completedAt: $now}' \
    >"${dir}/backup.json"
  jq -n --arg now "${now}" '{
    recoveryId: "ar-20260101T000000Z-abc123", status: "PASS", isolated: true,
    allVerificationGatesPassed: true, completedAt: $now}' >"${dir}/restore.json"
  jq -n --arg now "${now}" '{
    status: "PASS", sourceRevision: 3, targetChartVersion: "2.0.0",
    databaseMigration: "backward-compatible",
    rollbackStrategy: "database-restore", reviewedAt: $now}' \
    >"${dir}/compatibility.json"
}

run_pre_upgrade() {
  local dir="$1"
  "${TEST_BASH}" "${SELFHOST_DIR}/pre-upgrade-check.sh" \
    --namespace relay --release relay --target-chart ./chart \
    --backup-evidence "${dir}/backup.json" \
    --restore-evidence "${dir}/restore.json" \
    --compatibility-evidence "${dir}/compatibility.json" >/dev/null 2>&1
}

write_jobs() {
  # write_jobs JSON_STATUS... : one migration Job per status object.
  local items=""
  local index=0
  local status
  for status in "$@"; do
    index=$((index + 1))
    items="${items}${items:+,}{\"metadata\":{\"name\":\"relay-cloud-api-migrate-${index}\"},\"status\":${status}}"
  done
  printf '{"items":[%s]}\n' "${items}" >"${fixtures}/jobs.batch.json"
}

reset_fixtures
write_upgrade_evidence "${tmp_root}/upgrade"
complete='{"succeeded":1,"conditions":[{"type":"Complete","status":"True"}]}'
write_jobs "${complete}"
run_pre_upgrade "${tmp_root}/upgrade" || fail "pre-upgrade rejected a Complete migration Job"
# Succeeded after a retried pod: failed>0 but Complete=True.
write_jobs '{"failed":1,"succeeded":1,"conditions":[{"type":"Complete","status":"True"}]}'
run_pre_upgrade "${tmp_root}/upgrade" || fail "pre-upgrade rejected a Job that completed after a retry"
for status in '{"active":0,"failed":0}' \
  '{"conditions":[{"type":"Suspended","status":"True"}]}' \
  '{"active":1}' \
  '{"failed":3,"conditions":[{"type":"Failed","status":"True"}]}'; do
  write_jobs "${complete}" "${status}"
  if run_pre_upgrade "${tmp_root}/upgrade"; then
    fail "pre-upgrade accepted a migration Job that is not Complete=True: ${status}"
  fi
done
pass "pre-upgrade requires Complete=True on every migration Job"

# ---------------------------------------------------------------------------
# charts/agent-relay/scripts/gcp-recovery-backup.sh
# ---------------------------------------------------------------------------
write_backup_fixtures() {
  cat >"${fixtures}/gcloud-bucket.json" <<'JSON'
{"retentionPolicy":{"isLocked":true,"retentionPeriod":"3110400s"},
 "uniformBucketLevelAccess":{"enabled":true},"publicAccessPrevention":"enforced"}
JSON
  cat >"${fixtures}/gcloud-sql-instance.json" <<'JSON'
{"state":"RUNNABLE","settings":{"backupConfiguration":{"enabled":true,"pointInTimeRecoveryEnabled":true}}}
JSON
  cat >"${fixtures}/volumesnapshotclass.snapshot.storage.k8s.io.json" <<'JSON'
{"deletionPolicy":"Retain","driver":"pd.csi.storage.gke.io"}
JSON
  local pvc
  for pvc in relaycast-data relayauth-data; do
    jq -n --arg name "${pvc}" '{metadata: {name: $name}, status: {phase: "Bound"}}' \
      >"${fixtures}/pvc-${pvc}.json"
  done
  cat >"${fixtures}/volumesnapshot.json" <<'JSON'
{"metadata":{"name":"vs-test"},"spec":{"source":{"persistentVolumeClaimName":"relaycast-data"}},
 "status":{"readyToUse":true,"boundVolumeSnapshotContentName":"snapcontent-1"}}
JSON
  cat >"${fixtures}/volumesnapshotcontent.snapshot.storage.k8s.io.json" <<'JSON'
{"spec":{"deletionPolicy":"Retain","volumeSnapshotClassName":"retain","driver":"pd.csi.storage.gke.io"},
 "status":{"snapshotHandle":"projects/p/global/snapshots/s"}}
JSON
}

run_backup() {
  local pod_uid="$1"
  shift
  env "$@" POD_UID="${pod_uid}" PROJECT_ID=relay-project CLOUDSQL_INSTANCE=relay-db \
    CLOUDSQL_DATABASES=cloud,history GCS_SOURCE_BUCKET=relay-source \
    GCS_ARCHIVE_BUCKET=relay-archive SNAPSHOT_CLASS=retain \
    RELAYCAST_PVC=relaycast-data RELAYAUTH_PVC=relayauth-data \
    KUBERNETES_NAMESPACE=relay HELM_RELEASE=relay RETENTION_DAYS=36 \
    RPO_MINUTES=15 RTO_HOURS=4 \
    "${TEST_BASH}" "${RECOVERY_DIR}/gcp-recovery-backup.sh" >"${tmp_root}/backup.out" 2>&1
}

latest_backup_evidence() {
  find "${gcs}/relay-archive/recovery" -path '*/evidence/backup.json' | LC_ALL=C sort | tail -n 1
}

reset_fixtures
write_backup_fixtures
run_backup 1111aaaa || { cat "${tmp_root}/backup.out" >&2; fail "mocked backup failed"; }
run_backup 2222bbbb || { cat "${tmp_root}/backup.out" >&2; fail "second backup in the same second collided"; }
grep -Eq '^created vs-ar-[0-9]{8}t[0-9]{6}z-1111aaaa-relaycast$' "${command_log}" ||
  fail "snapshot name does not carry the recovery ID suffix"
grep -Eq '^created vs-ar-[0-9]{8}t[0-9]{6}z-2222bbbb-relayauth$' "${command_log}" ||
  fail "second capture did not get its own snapshot names"
pass "backup snapshot names carry the full recovery ID"

reset_fixtures
write_backup_fixtures
run_backup 3333cccc || { cat "${tmp_root}/backup.out" >&2; fail "crash-consistent backup failed"; }
jq -e '.sourceRevision == 3 and .writesQuiesced == false and .consistency == "crash-consistent"' \
  "$(latest_backup_evidence)" >/dev/null ||
  fail "unquiesced backup evidence must record sourceRevision and writesQuiesced=false"

reset_fixtures
write_backup_fixtures
cat >"${fixtures}/deployments.apps,statefulsets.apps.json" <<'JSON'
{"items":[{"kind":"Deployment","spec":{"replicas":0},"status":{"replicas":0}},
  {"kind":"StatefulSet","spec":{"replicas":0},"status":{}}]}
JSON
run_backup 4444dddd || { cat "${tmp_root}/backup.out" >&2; fail "quiesced backup failed"; }
quiesced_evidence="$(latest_backup_evidence)"
jq -e '.sourceRevision == 3 and .writesQuiesced == true and .consistency == "quiesced"' \
  "${quiesced_evidence}" >/dev/null ||
  fail "verified-quiesced backup evidence must record writesQuiesced=true"

# The evidence the script writes must satisfy the documented pre-upgrade gate.
write_upgrade_evidence "${tmp_root}/gate"
cp "${quiesced_evidence}" "${tmp_root}/gate/backup.json"
recovery_id="$(jq -r '.recoveryId' "${quiesced_evidence}")"
jq --arg id "${recovery_id}" '.recoveryId = $id' "${tmp_root}/gate/restore.json" \
  >"${tmp_root}/gate/restore.tmp" && mv "${tmp_root}/gate/restore.tmp" "${tmp_root}/gate/restore.json"
write_jobs "${complete}"
run_pre_upgrade "${tmp_root}/gate" || fail "pre-upgrade rejected evidence produced by the backup script"

reset_fixtures
write_backup_fixtures
if run_backup 5555eeee REQUIRE_WRITES_QUIESCED=true; then
  fail "REQUIRE_WRITES_QUIESCED accepted running writers"
fi
find "${gcs}" -name FAILED.json | grep -q . || fail "quiesce failure did not write FAILED.json"
jq -e '.sourceRevision == 3 and .failedPhase == "quiesce-preflight"' \
  "$(find "${gcs}" -name FAILED.json | head -n 1)" >/dev/null ||
  fail "failure evidence lacks sourceRevision or phase"

reset_fixtures
write_backup_fixtures
printf '3\n4\n' >"${fixtures}/helm-revisions"
if run_backup 6666ffff; then
  fail "backup accepted a Helm revision change during capture"
fi
if find "${gcs}" -name COMPLETE | grep -q .; then
  fail "backup marked COMPLETE although the revision changed"
fi
pass "backup evidence records sourceRevision and verified writesQuiesced"

# ---------------------------------------------------------------------------
# Restore-drill request, record, and audit
# ---------------------------------------------------------------------------
run_drill_request() {
  env POD_UID="${1:-req1}" GCS_ARCHIVE_BUCKET=relay-archive HELM_RELEASE=relay \
    "${TEST_BASH}" "${RECOVERY_DIR}/gcp-restore-drill-request.sh" >"${tmp_root}/request.out" 2>&1
}

reset_fixtures
write_backup_fixtures
run_backup 7777aaaa || { cat "${tmp_root}/backup.out" >&2; fail "backup for drill tests failed"; }
run_drill_request || { cat "${tmp_root}/request.out" >&2; fail "drill request failed"; }
grep -q '^gcloud storage cp --if-generation-match=0 .*/request.json' "${command_log}" ||
  fail "drill request upload is not create-only"
pass "drill request upload uses --if-generation-match=0"

printf 'All self-hosted script tests passed.\n'
