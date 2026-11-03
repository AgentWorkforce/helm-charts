#!/usr/bin/env bash
#
# End-to-end proof of a self-hosted Agent Relay suite on GKE (the gcp-proof
# layout): Relaycast messaging, control-plane bootstrap and device auth,
# RelayHistory durable delivery, dashboard reads, tenant isolation, restart
# durability, RelayAuth token verification, erasure, the 96bulls Sessions
# pipeline, and the public HTTPS edge.
#
# Every run creates fresh, uniquely marked test tenants. Nothing here prints a
# secret: credentials are read into a mode-0700 temp directory that is removed
# on exit, passed to in-cluster helpers on stdin, and never echoed. Output is
# line-oriented:
#
#   PROOF|PASS|<check>|<non-secret detail>
#   CASE|<n>|PASS|FAIL|SKIP|<name>
#   E2E_RESULT=PASS|FAIL
#
# Mutations: creates test organizations/workspaces/agents/sessions, and (unless
# --skip-restart) runs `kubectl rollout restart` on relayhistory and relaycast.
# It never changes Helm releases, NetworkPolicies, Secrets or the ingress.

set -uo pipefail

PROGRAM="${0##*/}"
HERE="$(cd "$(dirname "$0")" && pwd)"
DRIVER="$HERE/e2e-gcp-proof-driver.mjs"
BULLS_PROBE="$HERE/e2e-gcp-proof-96bulls.ts"

CONTEXT=""
NAMESPACE="agent-relay"
BULLS_NAMESPACE="96bulls"
SECRET_NAME="agent-relay-gcp-proof"
BASE_DOMAIN=""
SKIP_RESTART=false
SKIP_96BULLS=false
SKIP_PUBLIC=false
REQUIRE_PUBLIC=false
CERT_WAIT=0
PIPELINE_TIMEOUT=300
CLEANUP=false
VERIFY_PUBLIC="$HERE/../../.cursor/skills/setting-up-self-hosted-agent-relay-gcp/scripts/verify-public.sh"

usage() {
  cat <<'EOF'
Usage:
  e2e-gcp-proof.sh --context KUBE_CONTEXT [options]

Required:
      --context NAME          kubectl context of the proof cluster

Options:
  -n, --namespace NAME        agent-relay namespace (default: agent-relay)
      --bulls-namespace NAME  96bulls namespace (default: 96bulls)
      --secret NAME           release Secret holding relaycast-internal-secret
                              (default: agent-relay-gcp-proof)
      --base-domain DOMAIN    public base domain (default: derived from the
                              relay-cloud-api SELFHOST_PUBLIC_URL)
      --skip-restart          do not restart relayhistory/relaycast (case 6 SKIP)
      --skip-96bulls          skip the Sessions pipeline (case 8 SKIP)
      --skip-public           skip the public HTTPS checks (case 10 SKIP)
      --require-public        fail (not skip) case 10 when the cert is not Active
      --cert-wait SECONDS     wait up to this long for the ManagedCertificate
      --pipeline-timeout SEC  how long to wait for 96bulls workers (default 300)
      --cleanup               delete the two test Relaycast workspaces at the end
                              (case 11; a failed deletion fails the run)
  -h, --help                  show this help

Exit status: 0 when every case passes or is skipped, 1 on any failure,
2 on invalid usage.
EOF
}

die_usage() {
  printf '%s: %s\n' "$PROGRAM" "$1" >&2
  exit 2
}

# need_value <option> <argc>: a value-taking option must have a following
# argument; without this check `shift 2` fails, leaves $# unchanged and the
# loop never ends.
need_value() {
  (($2 >= 2)) || die_usage "$1 requires a value"
}

while (($#)); do
  case "$1" in
    --context|-n|--namespace|--bulls-namespace|--secret|--base-domain|--cert-wait|--pipeline-timeout)
      need_value "$1" "$#" ;;
  esac
  case "$1" in
    --context) CONTEXT="$2"; shift 2 ;;
    -n|--namespace) NAMESPACE="$2"; shift 2 ;;
    --bulls-namespace) BULLS_NAMESPACE="$2"; shift 2 ;;
    --secret) SECRET_NAME="$2"; shift 2 ;;
    --base-domain) BASE_DOMAIN="$2"; shift 2 ;;
    --skip-restart) SKIP_RESTART=true; shift ;;
    --skip-96bulls) SKIP_96BULLS=true; shift ;;
    --skip-public) SKIP_PUBLIC=true; shift ;;
    --require-public) REQUIRE_PUBLIC=true; shift ;;
    --cert-wait) CERT_WAIT="$2"; shift 2 ;;
    --pipeline-timeout) PIPELINE_TIMEOUT="$2"; shift 2 ;;
    --cleanup) CLEANUP=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die_usage "unknown option: $1" ;;
  esac
done

[[ -n "$CONTEXT" ]] || die_usage "--context is required"
[[ -n "$NAMESPACE" && -n "$BULLS_NAMESPACE" && -n "$SECRET_NAME" ]] || die_usage "namespace and secret options must not be empty"
[[ "$CERT_WAIT" =~ ^[0-9]+$ ]] || die_usage "--cert-wait must be a non-negative integer"
[[ "$PIPELINE_TIMEOUT" =~ ^[1-9][0-9]*$ ]] || die_usage "--pipeline-timeout must be a positive integer"
for f in "$DRIVER" "$BULLS_PROBE"; do
  [[ -f "$f" ]] || die_usage "missing helper: $f"
done
for tool in kubectl python3 curl; do
  command -v "$tool" >/dev/null 2>&1 || die_usage "missing tool: $tool"
done

K=(kubectl --context "$CONTEXT")
KN=("${K[@]}" -n "$NAMESPACE")
KB=("${K[@]}" -n "$BULLS_NAMESPACE")

WORK="$(mktemp -d "${TMPDIR:-/tmp}/e2e-gcp-proof.XXXXXX")"
chmod 700 "$WORK"
umask 077
STATE="$WORK/state.json"
RCS="$WORK/relaycast-internal-secret"
: >"$STATE"

API_POD=""
BULLS_POD=""

cleanup_exit() {
  if [[ -n "$API_POD" ]]; then
    "${KN[@]}" exec "$API_POD" -- rm -f /tmp/e2e-gcp-proof-driver.mjs >/dev/null 2>&1 || true
  fi
  if [[ -n "$BULLS_POD" ]]; then
    "${KB[@]}" exec "$BULLS_POD" -- rm -f /tmp/e2e-gcp-proof-96bulls.ts >/dev/null 2>&1 || true
  fi
  rm -rf "$WORK"
}
trap cleanup_exit EXIT

# ---------------------------------------------------------------- reporting

FAILS=0
CASE_LINES=()
CASE_FAILS=0
CASE_SKIPPED=""

emit() { # result check detail
  local detail="${3//$'\n'/ }"
  detail="${detail//|//}"
  printf 'PROOF|%s|%s|%s\n' "$1" "$2" "$detail"
  [[ "$1" == FAIL ]] && CASE_FAILS=$((CASE_FAILS + 1))
  return 0
}

case_begin() { CASE_FAILS=0; CASE_SKIPPED=""; printf '\n== case %s: %s (%s)\n' "$1" "$2" "$(date -u +%FT%TZ)"; }
case_skip() { CASE_SKIPPED="$1"; emit SKIP "case" "$1"; }
case_end() { # number name
  local result=PASS
  if ((CASE_FAILS > 0)); then
    result=FAIL
    FAILS=$((FAILS + 1))
  elif [[ -n "$CASE_SKIPPED" ]]; then
    result=SKIP
  fi
  CASE_LINES+=("CASE|$1|$result|$2")
}

# ---------------------------------------------------------------- helpers

ts() { date -u +%FT%TZ; }

find_pod() { # namespace selector
  "${K[@]}" -n "$1" get pods -l "$2" --field-selector=status.phase=Running \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
}

install_driver() {
  API_POD="$(find_pod "$NAMESPACE" 'app.kubernetes.io/name=relay-cloud-api,app.kubernetes.io/component=api')"
  [[ -n "$API_POD" ]] || return 1
  "${KN[@]}" exec -i "$API_POD" -- sh -c 'umask 077; cat > /tmp/e2e-gcp-proof-driver.mjs' <"$DRIVER"
}

# run_phase <phase>: feeds state + secret to the in-cluster driver, stores the
# new state, and prints only the driver's curated proof records.
run_phase() {
  local phase="$1" out="$WORK/out.json"
  if ! install_driver; then
    emit FAIL "$phase.driver" "relay-cloud-api pod unavailable"
    return 1
  fi
  local exec_rc
  python3 - "$STATE" "$RCS" <<'PY' | "${KN[@]}" exec -i "$API_POD" -- node /tmp/e2e-gcp-proof-driver.mjs "$phase" >"$out" 2>/dev/null
import json, sys
text = open(sys.argv[1]).read().strip()
state = json.loads(text) if text else {}
try:
    secret = open(sys.argv[2]).read()
except FileNotFoundError:
    secret = ""
state["secrets"] = {"relaycastInternalSecret": secret}
sys.stdout.write(json.dumps(state))
PY
  exec_rc=$?
  local parsed
  parsed="$(python3 - "$out" "$STATE" <<'PY'
import json, sys
try:
    result = json.load(open(sys.argv[1]))
    state, proofs = result["state"], result["proofs"]
    assert isinstance(state, dict) and isinstance(proofs, list)
except Exception:
    print("FAIL\tdriver.output\tunparseable driver output")
    raise SystemExit(0)
json.dump(state, open(sys.argv[2], "w"))
if not proofs:
    print("FAIL\tdriver.output\tdriver returned no proof records")
for p in proofs:
    print(f'{p["result"]}\t{p["check"]}\t{p["detail"]}')
PY
)"
  rm -f "$out"
  local result check detail
  while IFS=$'\t' read -r result check detail; do
    [[ -n "$result" ]] && emit "$result" "$check" "$detail"
  done <<<"$parsed"
  # The pipeline's status is the kubectl exec's (pipefail). The driver always
  # exits 0 after writing its result, so a non-zero status means the exec or
  # the node process itself failed.
  if ((exec_rc != 0)); then
    emit FAIL "$phase.exec" "kubectl exec rc=$exec_rc"
  fi
}

# emit_probe_output <label> <exec rc> <output> <required check>...
# Re-emits the probe's PROOF lines, then fails when the exec failed or any
# required check did not report PASS, so an empty or truncated output can
# never pass.
emit_probe_output() {
  local label="$1" rc="$2" out="$3" required
  shift 3
  while IFS='|' read -r _ result check detail; do emit "$result" "$check" "$detail"; done \
    < <(grep '^PROOF|' <<<"$out")
  ((rc == 0)) || emit FAIL "pipeline.${label}_exec" "kubectl exec rc=$rc"
  for required in "$@"; do
    grep -q "^PROOF|PASS|$required|" <<<"$out" ||
      emit FAIL "$required" "no PASS record from the $label probe"
  done
}

state_get() { # dotted.path -> value (non-secret fields only)
  python3 - "$STATE" "$1" <<'PY'
import json, sys
value = json.load(open(sys.argv[1]))
for part in sys.argv[2].split("."):
    value = value.get(part) if isinstance(value, dict) else None
print("" if value is None else value)
PY
}

state_set_json() { # key json
  python3 - "$STATE" "$1" "$2" <<'PY'
import json, sys
state = json.load(open(sys.argv[1]))
state[sys.argv[2]] = json.loads(sys.argv[3])
json.dump(state, open(sys.argv[1], "w"))
PY
}

state_pop_to_file() { # key file : moves a secret value out of the state
  python3 - "$STATE" "$1" "$2" <<'PY'
import json, sys
state = json.load(open(sys.argv[1]))
value = state.pop(sys.argv[2], "") or ""
json.dump(state, open(sys.argv[1], "w"))
open(sys.argv[3], "w").write(value)
PY
}

restart_and_wait() { # deployment
  local started
  started="$(ts)"
  if ! "${KN[@]}" rollout restart "deploy/$1" >/dev/null 2>&1; then
    emit FAIL "durability.restart_$1" "rollout restart failed"
    return 1
  fi
  if ! "${KN[@]}" rollout status "deploy/$1" --timeout=300s >/dev/null 2>&1; then
    emit FAIL "durability.restart_$1" "rollout did not become ready within 300s"
    return 1
  fi
  local pod
  pod="$("${KN[@]}" get pods -l "app.kubernetes.io/name=$1" --field-selector=status.phase=Running \
    -o jsonpath='{range .items[*]}{.metadata.name}{" "}{end}' 2>/dev/null)"
  emit PASS "durability.restart_$1" "restarted_at=$started ready_at=$(ts) pods=${pod% }"
}

# ---------------------------------------------------------------- preflight

printf 'E2E_CONTEXT=%s\nE2E_NAMESPACE=%s\nE2E_STARTED=%s\n' "$CONTEXT" "$NAMESPACE" "$(ts)"
if ! "${K[@]}" get namespace "$NAMESPACE" >/dev/null 2>&1; then
  printf 'E2E_RESULT=FAIL\nreason: cannot reach namespace %s with context %s\n' "$NAMESPACE" "$CONTEXT"
  exit 1
fi
if [[ -z "$BASE_DOMAIN" ]]; then
  api_url="$("${KN[@]}" get deploy relay-cloud-api \
    -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="SELFHOST_PUBLIC_URL")].value}' 2>/dev/null)"
  host="${api_url#https://}"
  BASE_DOMAIN="${host#api.}"
fi
printf 'E2E_BASE_DOMAIN=%s\n' "$BASE_DOMAIN"
"${KN[@]}" get secret "$SECRET_NAME" -o jsonpath='{.data.relaycast-internal-secret}' 2>/dev/null |
  python3 -c 'import base64, sys; sys.stdout.write(base64.b64decode(sys.stdin.read() or b"").decode())' >"$RCS"
[[ -s "$RCS" ]] || { printf 'E2E_RESULT=FAIL\nreason: relaycast-internal-secret not readable from %s\n' "$SECRET_NAME"; exit 1; }

# ---------------------------------------------------------------- cases 1-5

case_begin 1 "bootstrap"
run_phase bootstrap
case_end 1 "bootstrap: Relaycast admin workspace, control-plane org/workspace, device auth"
printf 'E2E_MARKER=%s\n' "$(state_get marker)"
BOOTSTRAPPED=$([[ -n "$(state_get a.workspaceId)" && -n "$(state_get b.workspaceId)" ]] && echo true || echo false)

case_begin 2 "messaging"
if $BOOTSTRAPPED; then run_phase messaging; else emit FAIL messaging.blocked "no tenant"; fi
case_end 2 "messaging: register, roster, A->B, B->A reply in the same conversation, history"

case_begin 3 "session delivery"
if $BOOTSTRAPPED; then run_phase delivery; else emit FAIL delivery.blocked "no tenant"; fi
case_end 3 "session delivery: durable receipt, identical retry, one projection"
DELIVERED=$([[ -n "$(state_get session.receiptId)" ]] && echo true || echo false)

case_begin 4 "reads"
if $DELIVERED; then run_phase reads; else emit FAIL reads.blocked "no delivered session"; fi
case_end 4 "reads: dashboard list/replay/search and RelayHistory direct"

case_begin 5 "isolation"
if $DELIVERED; then run_phase isolation; else emit FAIL isolation.blocked "no delivered session"; fi
case_end 5 "isolation: second workspace cannot read the first"

# ---------------------------------------------------------------- case 6

case_begin 6 "durability"
if $SKIP_RESTART; then
  case_skip "--skip-restart"
elif ! $DELIVERED; then
  emit FAIL durability.blocked "no delivered session"
else
  restart_and_wait relayhistory && run_phase durability-history
  restart_and_wait relaycast && run_phase durability-relaycast
fi
case_end 6 "durability: relayhistory and relaycast restarts"

# ---------------------------------------------------------------- case 7

case_begin 7 "auth"
if $BOOTSTRAPPED; then run_phase auth; else emit FAIL auth.blocked "no tenant"; fi
case_end 7 "auth: JWKS, RelayAuth assertion signature, token verification"

# ---------------------------------------------------------------- case 8

case_begin 8 "96bulls pipeline"
if $SKIP_96BULLS; then
  case_skip "--skip-96bulls"
else
  BULLS_POD="$(find_pod "$BULLS_NAMESPACE" 'app.kubernetes.io/name=alleyoop')"
  if [[ -z "$BULLS_POD" ]]; then
    emit FAIL pipeline.ingest_pod "no running alleyoop ingest pod"
  else
    env_of() {
      "${KB[@]}" get pod "$BULLS_POD" \
        -o jsonpath="{.spec.containers[0].env[?(@.name==\"$1\")].value}" 2>/dev/null
    }
    marker="$(state_get marker)"
    [[ -n "$marker" ]] || marker="e2e$(date +%s)"
    machine="e2e-$marker"
    state_set_json bulls "$(python3 -c 'import json,sys; print(json.dumps(dict(orgId=sys.argv[1], workspaceId=sys.argv[2] or "default", origin=sys.argv[3], machineId=sys.argv[4])))' \
      "$(env_of TENANT_ORG_ID)" "$(env_of WORKSPACE_ID)" "$(env_of RELAYHISTORY_ORIGIN)" "$machine")"
    [[ -n "$(state_get marker)" ]] || state_set_json marker "\"$marker\""
    if ! "${KB[@]}" exec -i "$BULLS_POD" -- sh -c 'umask 077; cat > /tmp/e2e-gcp-proof-96bulls.ts' <"$BULLS_PROBE"; then
      emit FAIL pipeline.install_probe "could not copy the probe into $BULLS_POD"
    fi
    pushed_at="$(date -u +%FT%TZ)"
    run_phase mint-96bulls
    state_pop_to_file bullsAssertion "$WORK/assertion"
    push_out="$("${KB[@]}" exec -i "$BULLS_POD" -- sh -c "cd /app && bun run /tmp/e2e-gcp-proof-96bulls.ts push '$marker' '$machine'" \
      <"$WORK/assertion" 2>/dev/null)"
    push_rc=$?
    rm -f "$WORK/assertion"
    emit_probe_output push "$push_rc" "$push_out" pipeline.courier_push
    bulls_session="$(sed -n 's/^SESSION_ID=//p' <<<"$push_out")"
    if [[ -n "$bulls_session" ]]; then
      verify_out="$("${KB[@]}" exec "$BULLS_POD" -- sh -c "cd /app && bun run /tmp/e2e-gcp-proof-96bulls.ts verify '$marker' '$bulls_session' '$PIPELINE_TIMEOUT'" 2>/dev/null)"
      verify_rc=$?
      emit_probe_output verify "$verify_rc" "$verify_out" \
        pipeline.hoopdb_indexer pipeline.referee_state pipeline.referee_verdict \
        pipeline.bob_costas_summaries pipeline.events pipeline.no_dead_letters \
        pipeline.bucket_objects pipeline.technical_foul_scrub
      trace="$(sed -n 's/^TRACE_ID=//p' <<<"$verify_out")"
      if [[ -z "$trace" ]]; then
        emit FAIL pipeline.trace "verify returned no trace id; worker logs not checked"
      else
        for worker in hoopdb-indexer referee bob-costas; do
          lines="$("${KB[@]}" logs "deploy/bulls96-worker-$worker" --since-time="$pushed_at" 2>/dev/null | grep -c -- "$trace")"
          leaks="$("${KB[@]}" logs "deploy/bulls96-worker-$worker" --since-time="$pushed_at" 2>/dev/null | grep -c -- "$marker")"
          if ((lines > 0 && leaks == 0)); then
            emit PASS "pipeline.logs_$worker" "trace_lines=$lines marker_in_logs=0"
          else
            emit FAIL "pipeline.logs_$worker" "trace_lines=$lines marker_in_logs=$leaks"
          fi
        done
      fi
    else
      emit FAIL pipeline.verify "courier push produced no session"
    fi
  fi
fi
case_end 8 "96bulls Sessions pipeline: courier push, indexer, referee, bob-costas, bucket"

# ---------------------------------------------------------------- case 9

case_begin 9 "erasure"
if $DELIVERED; then run_phase erasure; else emit FAIL erasure.blocked "no delivered session"; fi
case_end 9 "erasure: session removed from list, replay and search"

# ---------------------------------------------------------------- case 10

case_begin 10 "public edge"
cert_status() {
  "${KN[@]}" get managedcertificate -o jsonpath='{range .items[*]}{.status.certificateStatus}{"\n"}{end}' 2>/dev/null |
    sort -u | tr '\n' ' '
}
if $SKIP_PUBLIC; then
  case_skip "--skip-public"
else
  waited=0
  status="$(cert_status)"
  while [[ "$status" != "Active " ]] && ((waited < CERT_WAIT)); do
    step=$((CERT_WAIT - waited))
    ((step > 30)) && step=30
    sleep "$step"
    waited=$((waited + step))
    status="$(cert_status)"
  done
  if [[ "$status" != "Active " ]]; then
    domains="$("${KN[@]}" get managedcertificate -o jsonpath='{range .items[*].status.domainStatus[*]}{.domain}={.status}{" "}{end}' 2>/dev/null)"
    if $REQUIRE_PUBLIC; then
      emit FAIL public.certificate "status=${status% } domains=${domains% }"
    else
      emit SKIP public.certificate "status=${status% } domains=${domains% }"
      case_skip "ManagedCertificate not Active"
    fi
  else
    emit PASS public.certificate "status=Active"
    if [[ -x "$VERIFY_PUBLIC" || -f "$VERIFY_PUBLIC" ]]; then
      vp_out="$(BASE_DOMAIN="$BASE_DOMAIN" bash "$VERIFY_PUBLIC" 2>&1)"
      vp_rc=$?
      emit "$([[ $vp_rc -eq 0 ]] && echo PASS || echo FAIL)" public.verify_public \
        "rc=$vp_rc last=$(tail -n 1 <<<"$vp_out" | sed 's/^verify-public: //')"
      grep -E '^verify-public: ' <<<"$vp_out" | sed 's/^/  /'
    else
      emit FAIL public.verify_public "verify-public.sh not found"
    fi
    run_phase issue-public
    state_pop_to_file publicHistoryToken "$WORK/history-token"
    python3 - "$STATE" "$WORK" <<'PY'
import json, os, sys
state = json.load(open(sys.argv[1]))
work = sys.argv[2]
def header(name, token):
    with open(os.path.join(work, name), "w") as f:
        f.write(f"Authorization: Bearer {token}\n")
header("h-api", state["a"]["accessToken"])
header("h-api-b", state["b"]["accessToken"])
header("h-cast", state["a"]["relaycastKey"])
header("h-agent", state["agents"]["alpha"]["token"])
history = open(os.path.join(work, "history-token")).read()
header("h-history", history)
PY
    rm -f "$WORK/history-token"
    ws_a="$(state_get a.workspaceId)"
    pub() { # check expected header-file url
      local code
      code="$(curl --disable --silent --output /dev/null --max-time 20 --proto '=https' \
        --write-out '%{http_code}' ${3:+--header "@$WORK/$3"} "$4" 2>/dev/null)"
      if [[ "$code" == "$2" ]]; then emit PASS "$1" "status=$code"; else emit FAIL "$1" "status=$code expected=$2"; fi
    }
    pub public.api_whoami 200 h-api "https://api.$BASE_DOMAIN/api/v1/auth/whoami"
    pub public.api_resolve 200 h-api "https://api.$BASE_DOMAIN/api/v1/workspaces/$ws_a/resolve"
    pub public.dashboard_sessions 200 h-api "https://$BASE_DOMAIN/cloud/api/v1/workspaces/$ws_a/sessions"
    pub public.dashboard_cross_tenant 404 h-api-b "https://$BASE_DOMAIN/cloud/api/v1/workspaces/$ws_a/sessions"
    pub public.api_anonymous 401 "" "https://api.$BASE_DOMAIN/api/v1/auth/whoami"
    pub public.cast_roster 200 h-cast "https://cast.$BASE_DOMAIN/v1/agents"
    pub public.cast_agent 200 h-agent "https://cast.$BASE_DOMAIN/v1/agent"
    pub public.cast_anonymous 401 "" "https://cast.$BASE_DOMAIN/v1/agents"
    code="$(curl --disable -s -o /dev/null --max-time 20 -w '%{http_code}' -X POST \
      -H 'content-type: application/json' --data '{"name":"e2e-edge-probe"}' "https://cast.$BASE_DOMAIN/v1/workspaces")"
    # The chart routes this path to a selector-less Service, so the Google edge
    # answers 502 (no backend) and the request never reaches Relaycast.
    [[ "$code" == 502 || "$code" == 404 || "$code" == 403 ]] && emit PASS public.cast_workspace_create_denied "status=$code edge_denied=true" ||
      emit FAIL public.cast_workspace_create_denied "status=$code"
    code="$(curl --disable -s -o /dev/null --max-time 20 -w '%{http_code}' "https://cast.$BASE_DOMAIN/internal/capabilities")"
    # The chart routes this path to a selector-less Service, so the Google edge
    # answers 502 (no backend) and the request never reaches Relaycast.
    [[ "$code" == 502 || "$code" == 404 || "$code" == 403 ]] && emit PASS public.cast_internal_denied "status=$code edge_denied=true" ||
      emit FAIL public.cast_internal_denied "status=$code"
    pub public.history_sessions 200 h-history "https://history.$BASE_DOMAIN/v1/sessions?workspace=$ws_a&limit=1"
    pub public.history_anonymous 401 "" "https://history.$BASE_DOMAIN/v1/delivery/limits"
    rm -f "$WORK"/h-*
  fi
fi
case_end 10 "public: verify-public.sh and authenticated calls through the HTTPS edge"

# ---------------------------------------------------------------- cleanup

# Cleanup is its own case so a failed deletion fails the run.
if $CLEANUP; then
  case_begin 11 "cleanup"
  run_phase cleanup
  case_end 11 "cleanup: delete the two test Relaycast workspaces"
fi

printf '\n== summary (%s)\n' "$(ts)"
printf 'E2E_MARKER=%s\n' "$(state_get marker)"
for line in "${CASE_LINES[@]}"; do printf '%s\n' "$line"; done
if ((FAILS == 0)); then
  printf 'E2E_RESULT=PASS\n'
  exit 0
fi
printf 'E2E_RESULT=FAIL\n'
exit 1
