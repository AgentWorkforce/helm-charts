#!/usr/bin/env bash
#
# Read-only smoke verification for an agent-relay Helm release.
# This script never requests Kubernetes Secret resources and never prints
# command output, response bodies, manifests, or certificate contents.

set -uo pipefail

PROGRAM="${0##*/}"
NAMESPACE=""
RELEASE=""
CONTEXT=""
SELECTOR=""
MIGRATION_SELECTOR=""
INGRESS_HOST=""
HEALTH_PATH="/health"
TIMEOUT_SECONDS=15
CERT_MIN_VALID_SECONDS=86400
ALLOW_MISSING_MIGRATIONS=false
ALLOW_MISSING_WORKLOADS=false
ALLOW_MISSING_INGRESS=false
ALLOW_NO_TLS=false
HEALTH_URLS=()

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

usage() {
  cat <<'EOF'
Usage:
  verify-agent-relay.sh --namespace NAMESPACE --release RELEASE [options]

Required:
  -n, --namespace NAME             Kubernetes namespace
  -r, --release NAME               Helm release name

Selection:
      --context NAME               kubectl/Helm context
      --selector SELECTOR          Suite label selector
                                   (default: app.kubernetes.io/instance=RELEASE)
      --migration-selector SELECTOR
                                   Select all migration Jobs explicitly

Ingress and health:
      --ingress-host HOST          Verify only this ingress host
      --health-url URL             Health URL; repeat for multiple endpoints
      --health-path PATH           Derived ingress health path (default: /health)
      --timeout SECONDS            Per-network-check timeout (default: 15)
      --cert-min-valid SECONDS     Required remaining TLS validity (default: 86400)

Explicit exceptions:
      --allow-missing-migrations   Permit no discoverable migration Jobs
      --allow-missing-workloads    Permit no controller workloads
      --allow-missing-ingress      Permit no ingress and skip derived health/TLS
      --allow-no-tls               Permit ingress without TLS

Other:
  -h, --help                       Show this help

Output:
  PROOF|PASS|check|detail
  PROOF|FAIL|check|detail
  PROOF|SKIP|check|detail
  PROOF_RESULT=PASS|FAIL
  PROOF_COUNTS pass=N fail=N skip=N
EOF
}

proof() {
  local result="$1"
  local check="$2"
  local detail="$3"

  # Callers provide only curated, non-secret details. Normalize delimiters and
  # line breaks so every result remains one parseable record.
  detail="${detail//$'\n'/ }"
  detail="${detail//$'\r'/ }"
  detail="${detail//|//}"

  printf 'PROOF|%s|%s|%s\n' "$result" "$check" "$detail"
  case "$result" in
    PASS) PASS_COUNT=$((PASS_COUNT + 1)) ;;
    FAIL) FAIL_COUNT=$((FAIL_COUNT + 1)) ;;
    SKIP) SKIP_COUNT=$((SKIP_COUNT + 1)) ;;
  esac
}

die_usage() {
  printf '%s: %s\n' "$PROGRAM" "$1" >&2
  printf 'Run %s --help for usage.\n' "$PROGRAM" >&2
  exit 2
}

is_positive_integer() {
  [[ "$1" =~ ^[1-9][0-9]*$ ]]
}

validate_health_url() {
  python3 - "$1" <<'PY'
import sys
from urllib.parse import urlsplit

try:
    value = urlsplit(sys.argv[1])
except ValueError:
    raise SystemExit(1)

if value.scheme not in {"http", "https"}:
    raise SystemExit(1)
if not value.hostname or value.username is not None or value.password is not None:
    raise SystemExit(1)
if value.query or value.fragment:
    raise SystemExit(1)
try:
    value.port
except ValueError:
    raise SystemExit(1)
PY
}

while (($#)); do
  case "$1" in
    -n|--namespace)
      (($# >= 2)) || die_usage "$1 requires a value"
      NAMESPACE="$2"
      shift 2
      ;;
    -r|--release)
      (($# >= 2)) || die_usage "$1 requires a value"
      RELEASE="$2"
      shift 2
      ;;
    --context)
      (($# >= 2)) || die_usage "$1 requires a value"
      CONTEXT="$2"
      shift 2
      ;;
    --selector)
      (($# >= 2)) || die_usage "$1 requires a value"
      SELECTOR="$2"
      shift 2
      ;;
    --migration-selector)
      (($# >= 2)) || die_usage "$1 requires a value"
      MIGRATION_SELECTOR="$2"
      shift 2
      ;;
    --ingress-host)
      (($# >= 2)) || die_usage "$1 requires a value"
      INGRESS_HOST="$2"
      shift 2
      ;;
    --health-url)
      (($# >= 2)) || die_usage "$1 requires a value"
      HEALTH_URLS+=("$2")
      shift 2
      ;;
    --health-path)
      (($# >= 2)) || die_usage "$1 requires a value"
      HEALTH_PATH="$2"
      shift 2
      ;;
    --timeout)
      (($# >= 2)) || die_usage "$1 requires a value"
      TIMEOUT_SECONDS="$2"
      shift 2
      ;;
    --cert-min-valid)
      (($# >= 2)) || die_usage "$1 requires a value"
      CERT_MIN_VALID_SECONDS="$2"
      shift 2
      ;;
    --allow-missing-migrations)
      ALLOW_MISSING_MIGRATIONS=true
      shift
      ;;
    --allow-missing-workloads)
      ALLOW_MISSING_WORKLOADS=true
      shift
      ;;
    --allow-missing-ingress)
      ALLOW_MISSING_INGRESS=true
      shift
      ;;
    --allow-no-tls)
      ALLOW_NO_TLS=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      (($# == 0)) || die_usage "positional arguments are not supported"
      ;;
    -*)
      die_usage "unknown option: $1"
      ;;
    *)
      die_usage "positional arguments are not supported: $1"
      ;;
  esac
done

[[ -n "$NAMESPACE" ]] || die_usage "--namespace is required"
[[ -n "$RELEASE" ]] || die_usage "--release is required"
[[ "$NAMESPACE" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] ||
  die_usage "--namespace must be a DNS label"
[[ "$RELEASE" =~ ^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$ ]] ||
  die_usage "--release contains unsupported characters"
[[ "$HEALTH_PATH" == /* ]] || die_usage "--health-path must start with /"
[[ "$HEALTH_PATH" != *$'\n'* && "$HEALTH_PATH" != *$'\r'* ]] ||
  die_usage "--health-path must be one line"
is_positive_integer "$TIMEOUT_SECONDS" || die_usage "--timeout must be a positive integer"
is_positive_integer "$CERT_MIN_VALID_SECONDS" ||
  die_usage "--cert-min-valid must be a positive integer"

if [[ -n "$INGRESS_HOST" ]]; then
  [[ "$INGRESS_HOST" =~ ^([A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?\.)*[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] ||
    die_usage "--ingress-host is not a valid DNS host"
fi

for health_url in "${HEALTH_URLS[@]}"; do
  validate_health_url "$health_url" ||
    die_usage "--health-url must be HTTP(S), contain a host, and contain no credentials, query, or fragment"
done

[[ -n "$SELECTOR" ]] || SELECTOR="app.kubernetes.io/instance=$RELEASE"

missing_tools=()
for tool in helm kubectl python3 curl openssl timeout; do
  command -v "$tool" >/dev/null 2>&1 || missing_tools+=("$tool")
done
if ((${#missing_tools[@]})); then
  proof FAIL prerequisites "missing_tools=${missing_tools[*]}"
  printf 'PROOF_RESULT=FAIL\n'
  printf 'PROOF_COUNTS pass=%d fail=%d skip=%d\n' "$PASS_COUNT" "$FAIL_COUNT" "$SKIP_COUNT"
  exit 1
fi
proof PASS prerequisites "required_tools_present"

KUBECTL=(kubectl)
HELM=(helm)
if [[ -n "$CONTEXT" ]]; then
  KUBECTL+=(--context "$CONTEXT")
  HELM+=(--kube-context "$CONTEXT")
fi
KUBECTL+=(--namespace "$NAMESPACE")

# Helm release status. Raw Helm output is parsed in memory and never printed.
release_state="$(
  "${HELM[@]}" status "$RELEASE" --namespace "$NAMESPACE" --output json 2>/dev/null |
    python3 -c '
import json, sys
data = json.load(sys.stdin)
status = data.get("info", {}).get("status", "")
if not isinstance(status, str):
    raise SystemExit(1)
print(status)
' 2>/dev/null
)"
release_rc=$?
if ((release_rc != 0)); then
  proof FAIL release "helm_status_unavailable"
elif [[ "$release_state" == "deployed" ]]; then
  proof PASS release "status=deployed"
else
  proof FAIL release "status_not_deployed"
fi

# Jobs are selected explicitly when requested. Otherwise, discover release
# Jobs whose names or common component labels indicate migration/schema work.
migration_json="$(
  "${KUBECTL[@]}" get jobs.batch -l "${MIGRATION_SELECTOR:-$SELECTOR}" -o json 2>/dev/null
)"
migration_get_rc=$?
if ((migration_get_rc != 0)); then
  proof FAIL migrations "job_query_failed"
else
  migration_summary="$(
    printf '%s' "$migration_json" |
      MIGRATION_MODE="$([[ -n "$MIGRATION_SELECTOR" ]] && printf explicit || printf discover)" \
      python3 -c '
import json, os, re, sys
data = json.load(sys.stdin)
explicit = os.environ["MIGRATION_MODE"] == "explicit"
matched = []
for item in data.get("items", []):
    metadata = item.get("metadata", {})
    labels = metadata.get("labels", {})
    text = " ".join([
        metadata.get("name", ""),
        labels.get("app.kubernetes.io/component", ""),
        labels.get("app.kubernetes.io/name", ""),
        labels.get("job-type", ""),
    ])
    if explicit or re.search(r"(migrat|schema|database[-_]?setup|db[-_]?setup)", text, re.I):
        matched.append(item)

failed = 0
incomplete = 0
for item in matched:
    status = item.get("status", {})
    conditions = {
        c.get("type"): c.get("status")
        for c in status.get("conditions", [])
    }
    if status.get("failed", 0) > 0 or conditions.get("Failed") == "True":
        failed += 1
    elif conditions.get("Complete") != "True":
        incomplete += 1
print(len(matched), failed, incomplete)
' 2>/dev/null
  )"
  migration_parse_rc=$?
  if ((migration_parse_rc != 0)); then
    proof FAIL migrations "job_status_parse_failed"
  else
    read -r migration_count migration_failed migration_incomplete <<<"$migration_summary"
    if ((migration_count == 0)); then
      if $ALLOW_MISSING_MIGRATIONS; then
        proof SKIP migrations "no_migration_jobs_allowed"
      else
        proof FAIL migrations "no_migration_evidence"
      fi
    elif ((migration_failed > 0)); then
      proof FAIL migrations "jobs=$migration_count failed=$migration_failed"
    elif ((migration_incomplete > 0)); then
      proof FAIL migrations "jobs=$migration_count incomplete=$migration_incomplete"
    else
      proof PASS migrations "jobs=$migration_count complete=$migration_count"
    fi
  fi
fi

# Controller health is evaluated without fetching manifests or pod logs.
workload_count=0
workload_json="$(
  "${KUBECTL[@]}" get deployments.apps,statefulsets.apps,daemonsets.apps \
    -l "$SELECTOR" -o json 2>/dev/null
)"
workload_get_rc=$?
if ((workload_get_rc != 0)); then
  proof FAIL workloads "controller_query_failed"
else
  workload_summary="$(
    printf '%s' "$workload_json" |
      python3 -c '
import json, sys
data = json.load(sys.stdin)
items = data.get("items", [])
unready = 0
for item in items:
    kind = item.get("kind", "")
    metadata = item.get("metadata", {})
    spec = item.get("spec", {})
    status = item.get("status", {})
    generation = metadata.get("generation", 0)
    observed = status.get("observedGeneration", 0)
    ready = True
    if observed < generation:
        ready = False
    if kind == "Deployment":
        desired = spec.get("replicas", 1)
        ready = ready and status.get("availableReplicas", 0) >= desired
        ready = ready and status.get("updatedReplicas", 0) >= desired
        ready = ready and status.get("unavailableReplicas", 0) == 0
    elif kind == "StatefulSet":
        desired = spec.get("replicas", 1)
        ready = ready and status.get("readyReplicas", 0) >= desired
        ready = ready and status.get("updatedReplicas", 0) >= desired
    elif kind == "DaemonSet":
        desired = status.get("desiredNumberScheduled", 0)
        ready = ready and status.get("numberReady", 0) >= desired
        ready = ready and status.get("updatedNumberScheduled", 0) >= desired
        ready = ready and status.get("numberUnavailable", 0) == 0
    else:
        ready = False
    if not ready:
        unready += 1
print(len(items), unready)
' 2>/dev/null
  )"
  workload_parse_rc=$?
  if ((workload_parse_rc != 0)); then
    proof FAIL workloads "controller_status_parse_failed"
  else
    read -r workload_count workload_unready <<<"$workload_summary"
    if ((workload_count == 0)); then
      if $ALLOW_MISSING_WORKLOADS; then
        proof SKIP workloads "no_controllers_allowed"
      else
        proof FAIL workloads "no_controllers_found"
      fi
    elif ((workload_unready > 0)); then
      proof FAIL workloads "controllers=$workload_count unready=$workload_unready"
    else
      proof PASS workloads "controllers=$workload_count ready=$workload_count"
    fi
  fi
fi

pod_json="$("${KUBECTL[@]}" get pods -l "$SELECTOR" -o json 2>/dev/null)"
pod_get_rc=$?
if ((pod_get_rc != 0)); then
  proof FAIL pods "pod_query_failed"
else
  pod_summary="$(
    printf '%s' "$pod_json" |
      python3 -c '
import json, sys
data = json.load(sys.stdin)
items = data.get("items", [])
unhealthy = 0
for item in items:
    metadata = item.get("metadata", {})
    status = item.get("status", {})
    phase = status.get("phase", "")
    deleting = metadata.get("deletionTimestamp") is not None
    healthy = deleting or phase == "Succeeded"
    if phase == "Running" and not deleting:
        statuses = status.get("containerStatuses", [])
        healthy = bool(statuses) and all(s.get("ready") is True for s in statuses)
    if not healthy:
        unhealthy += 1
print(len(items), unhealthy)
' 2>/dev/null
  )"
  pod_parse_rc=$?
  if ((pod_parse_rc != 0)); then
    proof FAIL pods "pod_status_parse_failed"
  else
    read -r pod_count pod_unhealthy <<<"$pod_summary"
    if ((pod_count == 0 && workload_count > 0)); then
      proof FAIL pods "no_pods_for_controllers"
    elif ((pod_unhealthy > 0)); then
      proof FAIL pods "pods=$pod_count unhealthy=$pod_unhealthy"
    else
      proof PASS pods "pods=$pod_count unhealthy=0"
    fi
  fi
fi

ingress_json="$("${KUBECTL[@]}" get ingresses.networking.k8s.io -l "$SELECTOR" -o json 2>/dev/null)"
ingress_get_rc=$?
INGRESS_AVAILABLE=false
SELECTED_HOSTS=()
TLS_HOSTS=()
TLS_SECRET_REFS=()

if ((ingress_get_rc != 0)); then
  proof FAIL ingress "ingress_query_failed"
else
  ingress_summary="$(
    printf '%s' "$ingress_json" |
      INGRESS_HOST_FILTER="$INGRESS_HOST" python3 -c '
import json, os, sys
data = json.load(sys.stdin)
host_filter = os.environ.get("INGRESS_HOST_FILTER", "").lower()
items = data.get("items", [])
selected = []
for item in items:
    rules = item.get("spec", {}).get("rules", [])
    hosts = [r.get("host", "").lower() for r in rules if r.get("host")]
    if not host_filter or host_filter in hosts:
        selected.append(item)
admitted = 0
rule_hosts = set()
tls_hosts = set()
for item in selected:
    lb = item.get("status", {}).get("loadBalancer", {}).get("ingress", [])
    if any(x.get("hostname") or x.get("ip") for x in lb):
        admitted += 1
    for rule in item.get("spec", {}).get("rules", []):
        if rule.get("host"):
            rule_hosts.add(rule["host"].lower())
    for tls in item.get("spec", {}).get("tls", []):
        tls_hosts.update(h.lower() for h in tls.get("hosts", []) if h)
print(len(selected), admitted, len(rule_hosts), len(tls_hosts))
' 2>/dev/null
  )"
  ingress_parse_rc=$?
  if ((ingress_parse_rc != 0)); then
    proof FAIL ingress "ingress_status_parse_failed"
  else
    read -r ingress_count ingress_admitted ingress_host_count ingress_tls_host_count <<<"$ingress_summary"
    if ((ingress_count == 0)); then
      if $ALLOW_MISSING_INGRESS; then
        proof SKIP ingress "no_ingress_allowed"
      else
        proof FAIL ingress "no_matching_ingress"
      fi
    elif ((ingress_admitted != ingress_count)); then
      proof FAIL ingress "ingresses=$ingress_count admitted=$ingress_admitted"
    elif ((ingress_host_count == 0)); then
      proof FAIL ingress "no_rule_hosts"
    else
      INGRESS_AVAILABLE=true
      proof PASS ingress "ingresses=$ingress_count admitted=$ingress_admitted hosts=$ingress_host_count"
    fi

    if ((ingress_count > 0)); then
      mapfile -t SELECTED_HOSTS < <(
        printf '%s' "$ingress_json" |
          INGRESS_HOST_FILTER="$INGRESS_HOST" python3 -c '
import json, os, sys
data = json.load(sys.stdin)
host_filter = os.environ.get("INGRESS_HOST_FILTER", "").lower()
hosts = set()
for item in data.get("items", []):
    item_hosts = {
        r.get("host", "").lower()
        for r in item.get("spec", {}).get("rules", [])
        if r.get("host")
    }
    if not host_filter or host_filter in item_hosts:
        hosts.update(item_hosts)
for host in sorted(hosts):
    print(host)
'
      )
      mapfile -t TLS_HOSTS < <(
        printf '%s' "$ingress_json" |
          INGRESS_HOST_FILTER="$INGRESS_HOST" python3 -c '
import json, os, sys
data = json.load(sys.stdin)
host_filter = os.environ.get("INGRESS_HOST_FILTER", "").lower()
hosts = set()
for item in data.get("items", []):
    rule_hosts = {
        r.get("host", "").lower()
        for r in item.get("spec", {}).get("rules", [])
        if r.get("host")
    }
    if not host_filter or host_filter in rule_hosts:
        for tls in item.get("spec", {}).get("tls", []):
            hosts.update(h.lower() for h in tls.get("hosts", []) if h)
for host in sorted(hosts):
    if not host_filter or host == host_filter:
        print(host)
'
      )
      mapfile -t TLS_SECRET_REFS < <(
        printf '%s' "$ingress_json" |
          INGRESS_HOST_FILTER="$INGRESS_HOST" python3 -c '
import json, os, sys
data = json.load(sys.stdin)
host_filter = os.environ.get("INGRESS_HOST_FILTER", "").lower()
refs = set()
for item in data.get("items", []):
    rule_hosts = {
        r.get("host", "").lower()
        for r in item.get("spec", {}).get("rules", [])
        if r.get("host")
    }
    if not host_filter or host_filter in rule_hosts:
        refs.update(
            tls.get("secretName")
            for tls in item.get("spec", {}).get("tls", [])
            if tls.get("secretName")
        )
for ref in sorted(refs):
    print(ref)
'
      )
    fi
  fi
fi

# Use explicit health URLs, or derive HTTPS URLs from the selected ingress rules.
if ((${#HEALTH_URLS[@]} == 0)) && $INGRESS_AVAILABLE; then
  for host in "${SELECTED_HOSTS[@]}"; do
    HEALTH_URLS+=("https://${host}${HEALTH_PATH}")
  done
fi

if ((${#HEALTH_URLS[@]} == 0)); then
  if $ALLOW_MISSING_INGRESS; then
    proof SKIP health "no_health_endpoint"
  else
    proof FAIL health "no_health_endpoint"
  fi
else
  health_failures=0
  health_index=0
  for health_url in "${HEALTH_URLS[@]}"; do
    health_index=$((health_index + 1))
    http_code="$(
      curl --disable --silent --show-error --output /dev/null --max-time "$TIMEOUT_SECONDS" \
        --write-out '%{http_code}' "$health_url" 2>/dev/null
    )"
    curl_rc=$?
    if ((curl_rc == 0)) && [[ "$http_code" =~ ^2[0-9][0-9]$ ]]; then
      proof PASS "health[$health_index]" "http_status=$http_code"
    else
      proof FAIL "health[$health_index]" "request_or_status_failed"
      health_failures=$((health_failures + 1))
    fi
  done
fi

if ((${#TLS_HOSTS[@]} == 0)); then
  if $ALLOW_NO_TLS || $ALLOW_MISSING_INGRESS; then
    proof SKIP certificate "no_tls_hosts_allowed"
  else
    proof FAIL certificate "no_tls_hosts"
  fi
else
  cert_index=0
  for tls_host in "${TLS_HOSTS[@]}"; do
    cert_index=$((cert_index + 1))
    if timeout "$TIMEOUT_SECONDS" openssl s_client \
      -connect "${tls_host}:443" \
      -servername "$tls_host" \
      -verify_hostname "$tls_host" \
      -verify_return_error </dev/null 2>/dev/null |
      openssl x509 -noout -checkend "$CERT_MIN_VALID_SECONDS" >/dev/null 2>&1; then
      proof PASS "certificate[$cert_index]" "trusted_hostname_valid_and_not_expiring"
    else
      proof FAIL "certificate[$cert_index]" "tls_validation_failed"
    fi
  done
fi

# If cert-manager is installed, corroborate public TLS checks using Certificate
# status only. Certificate resources may refer to Secrets, but Secret resources
# themselves are never requested. Secret reference names are never printed.
if "${KUBECTL[@]}" api-resources --api-group=cert-manager.io -o name 2>/dev/null |
  python3 -c 'import sys; raise SystemExit(0 if "certificates.cert-manager.io" in sys.stdin.read().split() else 1)'; then
  certificate_json="$("${KUBECTL[@]}" get certificates.cert-manager.io -o json 2>/dev/null)"
  certificate_get_rc=$?
  if ((certificate_get_rc != 0)); then
    proof FAIL cert_manager "certificate_query_failed"
  elif ((${#TLS_SECRET_REFS[@]} == 0)); then
    proof SKIP cert_manager "no_ingress_certificate_references"
  else
    cert_refs_joined="$(printf '%s\n' "${TLS_SECRET_REFS[@]}")"
    cert_manager_summary="$(
      printf '%s' "$certificate_json" |
        CERT_REFS="$cert_refs_joined" python3 -c '
import json, os, sys
refs = set(os.environ.get("CERT_REFS", "").splitlines())
data = json.load(sys.stdin)
matched = 0
unready = 0
for item in data.get("items", []):
    if item.get("spec", {}).get("secretName") not in refs:
        continue
    matched += 1
    ready = any(
        c.get("type") == "Ready" and c.get("status") == "True"
        for c in item.get("status", {}).get("conditions", [])
    )
    if not ready:
        unready += 1
print(matched, unready)
' 2>/dev/null
    )"
    cert_manager_parse_rc=$?
    if ((cert_manager_parse_rc != 0)); then
      proof FAIL cert_manager "certificate_status_parse_failed"
    else
      read -r cert_manager_count cert_manager_unready <<<"$cert_manager_summary"
      if ((cert_manager_count == 0)); then
        proof SKIP cert_manager "no_matching_certificate_objects"
      elif ((cert_manager_unready > 0)); then
        proof FAIL cert_manager "certificates=$cert_manager_count unready=$cert_manager_unready"
      else
        proof PASS cert_manager "certificates=$cert_manager_count ready=$cert_manager_count"
      fi
    fi
  fi
else
  proof SKIP cert_manager "api_not_installed"
fi

if ((FAIL_COUNT == 0)); then
  printf 'PROOF_RESULT=PASS\n'
  result_rc=0
else
  printf 'PROOF_RESULT=FAIL\n'
  result_rc=1
fi
printf 'PROOF_COUNTS pass=%d fail=%d skip=%d\n' "$PASS_COUNT" "$FAIL_COUNT" "$SKIP_COUNT"
exit "$result_rc"
