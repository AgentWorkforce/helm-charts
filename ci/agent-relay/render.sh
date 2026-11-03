#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."

# Helm does not recursively vendor file:// dependency children.
helm dependency build charts/96bulls >/dev/null
helm dependency build charts/agent-relay >/dev/null
out=$(helm template proof charts/agent-relay -n agent-relay --no-hooks \
  -f charts/agent-relay/values-gcp-proof.yaml \
  -f charts/agent-relay/ci/gcp-proof-values.yaml)

if grep -Eq 'app.kubernetes.io/name: (relayflows|relayfile)' <<<"$out"; then
  echo "proof render emits a relayflows/relayfile manifest" >&2
  exit 1
fi
if yq 'select(.kind == "Secret") | .metadata.name' <<<"$out" | grep -q .; then
  echo "proof render emits a Secret manifest" >&2
  exit 1
fi
if grep -Eq 'helm\.sh/hook:' <<<"$out"; then
  echo "proof render emits a Helm hook annotation" >&2
  exit 1
fi
test "$(yq 'select(.kind == "Ingress") | .metadata.name' <<<"$out" | grep -c .)" = 1
test "$(yq 'select(.kind == "ManagedCertificate") | .metadata.name' <<<"$out")" = agent-relay-gcp-proof
test "$(yq 'select(.kind == "FrontendConfig") | .spec.redirectToHttps.enabled' <<<"$out")" = true
test "$(yq 'select(.kind == "Ingress") | .metadata.annotations["kubernetes.io/ingress.global-static-ip-name"]' <<<"$out")" = agent-relay-gcp-proof-ingress

root_api=$(yq 'select(.kind == "Ingress" and .metadata.name == "agent-relay-gcp-proof") |
  .spec.rules[] | select(.host == "gcp-proof.agentrelay.com") |
  .http.paths[] | select(.path == "/cloud/api") | .backend.service.name' <<<"$out")
test "$root_api" = relay-cloud-api

root_login=$(yq 'select(.kind == "Ingress" and .metadata.name == "agent-relay-gcp-proof") |
  .spec.rules[] | select(.host == "gcp-proof.agentrelay.com") |
  .http.paths[] | select(.path == "/login") | .backend.service.name' <<<"$out")
test "$root_login" = relay-cloud-api

api_backend=$(yq 'select(.kind == "Ingress" and .metadata.name == "agent-relay-gcp-proof") |
  .spec.rules[] | select(.host == "api.gcp-proof.agentrelay.com") |
  .http.paths[] | select(.path == "/") | .backend.service.name' <<<"$out")
test "$api_backend" = relay-cloud-api

for host in gcp-proof.agentrelay.com api.gcp-proof.agentrelay.com \
  cast.gcp-proof.agentrelay.com history.gcp-proof.agentrelay.com; do
  grep -Eq "host: [\"']?${host}[\"']?$" <<<"$out"
done

for image in \
  us-central1-docker.pkg.dev/agentrelay-96bulls-soc2-2610/awf-conformance-images/selfhost-api \
  us-central1-docker.pkg.dev/agentrelay-96bulls-soc2-2610/awf-conformance-images/relay-dashboard \
  us-central1-docker.pkg.dev/agentrelay-96bulls-soc2-2610/awf-conformance-images/relayhistory; do
  grep -Eq "image: [\"']?${image}@sha256:[a-f0-9]{64}" <<<"$out"
done

for service in relaycast relayhistory relay-cloud-api relay-dashboard; do
  test "$(yq "select(.kind == \"Service\" and .metadata.name == \"$service\") |
    .metadata.annotations[\"cloud.google.com/neg\"]" <<<"$out")" = '{"ingress": true}'
done

api_history_url=$(yq 'select(.kind == "Deployment" and .metadata.name == "relay-cloud-api") |
  .spec.template.spec.containers[0].env[] | select(.name == "RELAYHISTORY_URL") | .value' <<<"$out")
api_history_public_url=$(yq 'select(.kind == "Deployment" and .metadata.name == "relay-cloud-api") |
  .spec.template.spec.containers[0].env[] | select(.name == "RELAYHISTORY_PUBLIC_URL") | .value' <<<"$out")
api_cast_public_url=$(yq 'select(.kind == "Deployment" and .metadata.name == "relay-cloud-api") |
  .spec.template.spec.containers[0].env[] | select(.name == "RELAYCAST_PUBLIC_URL") | .value' <<<"$out")
history_audience=$(yq 'select(.kind == "ConfigMap" and .metadata.name == "relayhistory") |
  .data.RELAYAUTH_AUDIENCE' <<<"$out")
test "$api_history_url" = http://relayhistory:8080
test "$api_history_public_url" = https://history.gcp-proof.agentrelay.com
test "$api_history_public_url" = "$history_audience"
test "$api_cast_public_url" = https://cast.gcp-proof.agentrelay.com

# /internal on the api host is denied at the edge, like the cast host.
api_internal=$(yq 'select(.kind == "Ingress" and .metadata.name == "agent-relay-gcp-proof") |
  .spec.rules[] | select(.host == "api.gcp-proof.agentrelay.com") |
  .http.paths[] | select(.path == "/internal") | .backend.service.name + " " + .pathType' <<<"$out")
test "$api_internal" = "agent-relay-gcp-proof-cast-edge-deny Prefix" \
  || { echo "api host does not deny /internal at the edge ($api_internal)" >&2; exit 1; }
cast_internal=$(yq 'select(.kind == "Ingress" and .metadata.name == "agent-relay-gcp-proof") |
  .spec.rules[] | select(.host == "cast.gcp-proof.agentrelay.com") |
  .http.paths[] | select(.path == "/internal") | .backend.service.name' <<<"$out")
test "$cast_internal" = agent-relay-gcp-proof-cast-edge-deny
# The edge-deny Service must never select pods.
test "$(yq 'select(.kind == "Service" and .metadata.name == "agent-relay-gcp-proof-cast-edge-deny") | .spec.selector' <<<"$out")" = null

# The api backend gets a BackendConfig timeout above GCE's 30s default for
# the flows worker queue SSE stream, bound through the api Service.
test "$(yq 'select(.kind == "BackendConfig" and .metadata.name == "agent-relay-gcp-proof-api") | .spec.timeoutSec' <<<"$out")" -ge 60
test "$(yq 'select(.kind == "Service" and .metadata.name == "relay-cloud-api") |
  .metadata.annotations["cloud.google.com/backend-config"]' <<<"$out")" = '{"default":"agent-relay-gcp-proof-api"}'
expect_umbrella_failure() { # expected-error helm-args...
  local expected=$1 output; shift
  if output=$(helm template proof charts/agent-relay -n agent-relay --no-hooks \
    -f charts/agent-relay/values-gcp-proof.yaml -f charts/agent-relay/ci/gcp-proof-values.yaml "$@" 2>&1); then
    echo "agent-relay: rendered despite expected failure: $expected" >&2
    exit 1
  fi
  grep -Fq "$expected" <<<"$output" \
    || { echo "agent-relay: failed without expected error: $expected" >&2; echo "$output" >&2; exit 1; }
}
expect_umbrella_failure "gkeIngress.backends.api.timeoutSec must be at least 60" --set gkeIngress.backends.api.timeoutSec=30
expect_umbrella_failure "relay-cloud-api.service.backendConfig=agent-relay-gcp-proof-api" \
  --set relay-cloud-api.service.backendConfig=null
expect_umbrella_failure "relay-cloud-api.service.backendConfig=agent-relay-gcp-proof-api" \
  --set relay-cloud-api.service.backendConfig=other-api
# Long names keep the -api suffix: truncate to 59, then append.
long_name=$(printf 'n%.0s' $(seq 70))
long_bc="$(printf 'n%.0s' $(seq 59))-api"
long_out=$(helm template proof charts/agent-relay -n agent-relay --no-hooks \
  -f charts/agent-relay/values-gcp-proof.yaml -f charts/agent-relay/ci/gcp-proof-values.yaml \
  --set "gkeIngress.name=$long_name" --set "relay-cloud-api.service.backendConfig=$long_bc")
test "$(yq 'select(.kind == "BackendConfig") | .metadata.name' <<<"$long_out")" = "$long_bc" \
  || { echo "long gkeIngress.name lost the -api BackendConfig suffix" >&2; exit 1; }
# A customer name in the GCP profile renders once service.backendConfig follows it.
helm template ar charts/agent-relay -n agent-relay --no-hooks -f charts/agent-relay/values-gcp.yaml \
  --set gkeIngress.name=acme-relay --set relay-cloud-api.service.backendConfig=acme-relay-api >/dev/null \
  || { echo "values-gcp.yaml: customer gkeIngress.name with matching backendConfig failed to render" >&2; exit 1; }
if acme_fail=$(helm template ar charts/agent-relay -n agent-relay --no-hooks -f charts/agent-relay/values-gcp.yaml \
  --set gkeIngress.name=acme-relay 2>&1); then
  echo "values-gcp.yaml: stale service.backendConfig rendered" >&2; exit 1
fi
grep -Fq 'relay-cloud-api.service.backendConfig=acme-relay-api' <<<"$acme_fail" \
  || { echo "values-gcp.yaml: stale backendConfig failed without naming the expected value" >&2; echo "$acme_fail" >&2; exit 1; }
expect_leaf_failure_early() { # expected helm-args...
  local expected=$1 output; shift
  if output=$(helm template ci charts/relay-cloud-api -n ci --no-hooks -f charts/relay-cloud-api/ci/default-values.yaml "$@" 2>&1); then
    echo "relay-cloud-api: rendered despite expected failure: $expected" >&2; exit 1
  fi
  grep -Fq "$expected" <<<"$output" || { echo "relay-cloud-api: failed without expected error: $expected" >&2; echo "$output" >&2; exit 1; }
}
expect_leaf_failure_early "not both" --set service.backendConfig=x-api \
  --set-json 'service.annotations={"cloud.google.com/backend-config":"{\"default\":\"x-api\"}"}'
expect_leaf_failure_early "service.backendConfig must be a BackendConfig name" --set service.backendConfig=Bad_Name
expect_umbrella_failure "flows.queuePingMs must be below gkeIngress.backends.api.timeoutSec" \
  --set gkeIngress.backends.api.timeoutSec=60 --set relay-cloud-api.flows.queuePingMs=60000
# encryption.keyId is required (relaycontrol crash-loops without it).
expect_umbrella_failure "encryption.keyId is required" --set relay-cloud-api.encryption.keyId=

live_out=$(helm template proof charts/agent-relay -n agent-relay --no-hooks \
  -f charts/agent-relay/values-gcp-proof.yaml \
  -f charts/agent-relay/values-gcp-proof-live.yaml \
  --set relay-cloud-api.image.digest=sha256:2222222222222222222222222222222222222222222222222222222222222222)
if yq 'select(.metadata.name == "relayauth") | .metadata.name' <<<"$live_out" | grep -q .; then
  echo "live profile renders a relayauth manifest" >&2
  exit 1
fi
netpol_names=$(yq 'select(.kind == "NetworkPolicy") | .metadata.name' <<<"$live_out" | grep -v '^---$' || true)
if [[ -z "$netpol_names" ]]; then
  echo "live profile renders no NetworkPolicies" >&2
  exit 1
fi
if grep -q '^relayauth' <<<"$netpol_names"; then
  echo "live profile renders a NetworkPolicy for disabled relayauth" >&2
  exit 1
fi
test "$(yq 'select(.kind == "Deployment" and .metadata.name == "relay-cloud-api") |
  .spec.template.spec.containers[0].env[] | select(.name == "RELAYAUTH_URL") | .value' <<<"$live_out")" = http://relayauth.relayauth.svc:8787
test "$(yq 'select(.kind == "ConfigMap" and .metadata.name == "relayhistory") |
  .data.RELAYAUTH_ISSUER' <<<"$live_out")" = http://relayauth.relayauth.svc:8787
test "$(yq 'select(.kind == "ConfigMap" and .metadata.name == "relayhistory") |
  .data.RELAYAUTH_JWKS_URL' <<<"$live_out")" = http://relayauth.relayauth.svc:8787/.well-known/jwks.json

live_api_env() { yq "select(.kind == \"Deployment\" and .metadata.name == \"relay-cloud-api\") |
  .spec.template.spec.containers[0].env[] | select(.name == \"$1\") | .value" <<<"$live_out"; }
test "$(live_api_env SELFHOST_ENCRYPTION_KEY_ID)" = proof-1
test "$(live_api_env SELFHOST_DASHBOARD_URL)" = https://gcp-proof.agentrelay.com/
test "$(live_api_env SELFHOST_INTERNAL_TOKEN_FILE)" = /var/run/agent-relay/secrets/selfhost-internal-token
test "$(live_api_env SELFHOST_TELEMETRY_LEVEL)" = off
test -z "$(live_api_env SELFHOST_TELEMETRY_INSTALL_KEY_FILE)"
yq 'select(.kind == "Deployment" and .metadata.name == "relay-cloud-api") | .spec.template.spec.volumes[] |
  select(.name == "secrets") | .secret.items[].key' <<<"$live_out" | grep -qx selfhost-internal-token \
  || { echo "live profile does not mount the internal token" >&2; exit 1; }

# ar_ credential custody: authority=relayauth without the relayauth component
# must fail closed at the umbrella level.
if ar_fail=$(helm template proof charts/agent-relay -n agent-relay --no-hooks \
  -f charts/agent-relay/values-gcp-proof.yaml \
  -f charts/agent-relay/ci/gcp-proof-values.yaml \
  --set components.relayauth=false \
  --set relaycast.credentials.format=ar \
  --set relaycast.credentials.authority=relayauth \
  --set relaycast.credentials.relayauth.url=http://relayauth:8787 \
  --set relaycast.secretKeys.relayauthToken=relaycast-relayauth-token 2>&1); then
  echo "authority=relayauth without components.relayauth rendered successfully" >&2
  exit 1
fi
grep -q 'requires components.relayauth=true' <<<"$ar_fail" \
  || { echo "render failed without the expected components.relayauth error" >&2; exit 1; }

# Migration Jobs: spec.template is immutable, so any pod template change
# (here: resources) must produce a new Job name.
proof_args=(-f charts/agent-relay/values-gcp-proof.yaml -f charts/agent-relay/ci/gcp-proof-values.yaml)
for child in relayhistory relay-cloud-api; do
  base_job=$(yq "select(.kind == \"Job\" and .metadata.name == \"${child}-migrate-*\") | .metadata.name" <<<"$out")
  resized=$(helm template proof charts/agent-relay -n agent-relay --no-hooks "${proof_args[@]}" \
    --set "${child}.resources.limits.memory=7Gi" |
    yq "select(.kind == \"Job\" and .metadata.name == \"${child}-migrate-*\") | .metadata.name")
  test -n "$base_job" || { echo "$child: no migration Job rendered" >&2; exit 1; }
  if [ "$base_job" = "$resized" ]; then
    echo "$child: migration Job name ignores pod template changes ($base_job)" >&2
    exit 1
  fi
done

# NOTES.txt waits on Jobs by component=migration; the Job object itself
# (not only its pods) must carry that label.
for child in relayhistory relay-cloud-api; do
  test "$(yq "select(.kind == \"Job\" and .metadata.name == \"${child}-migrate-*\") |
    .metadata.labels[\"app.kubernetes.io/component\"]" <<<"$out")" = migration \
    || { echo "$child: migration Job metadata lacks app.kubernetes.io/component=migration" >&2; exit 1; }
done

# Leaf-chart fail-closed validations for the suite's child charts, rendered
# standalone from their CI values.
expect_leaf_failure() { # chart expected-error helm-args...
  local chart=$1 expected=$2 output; shift 2
  if output=$(helm template ci "charts/$chart" -n ci --no-hooks -f "charts/$chart/ci/default-values.yaml" "$@" 2>&1); then
    echo "$chart: rendered despite expected failure: $expected" >&2
    exit 1
  fi
  grep -Fq "$expected" <<<"$output" \
    || { echo "$chart: failed without expected error: $expected" >&2; echo "$output" >&2; exit 1; }
}
db_egress='[{"to":[{"ipBlock":{"cidr":"10.20.0.0/24"}}],"ports":[{"protocol":"TCP","port":5432}]}]'
for child in relayhistory relay-cloud-api; do
  expect_leaf_failure "$child" "allowAllEgress=false requires networkPolicy.additionalEgress" \
    --set networkPolicy.allowAllEgress=false
  expect_leaf_failure "$child" "additionalEgress rule needs a non-empty to" \
    --set networkPolicy.allowAllEgress=false --set-json 'networkPolicy.additionalEgress=[{"ports":[{"port":5432}]}]'
  helm template ci "charts/$child" -n ci --no-hooks -f "charts/$child/ci/default-values.yaml" \
    --set networkPolicy.allowAllEgress=false --set-json "networkPolicy.additionalEgress=$db_egress" >/dev/null
done

# relayhistory: extraEnvFrom must not override chart-managed ConfigMap keys,
# so the chart ConfigMap is the last (winning) envFrom source.
last_env_from=$(helm template ci charts/relayhistory -n ci --no-hooks -f charts/relayhistory/ci/default-values.yaml \
  --set-json 'extraEnvFrom=[{"configMapRef":{"name":"operator-extra"}}]' |
  yq 'select(.kind == "Deployment") | .spec.template.spec.containers[0].envFrom[-1].configMapRef.name')
test "$last_env_from" = ci-relayhistory \
  || { echo "relayhistory: extraEnvFrom can override the chart ConfigMap (last envFrom is $last_env_from)" >&2; exit 1; }

# relay-cloud-api runtime contract (relaycontrol src/config.ts): fail closed at
# render time on what the API refuses at startup.
expect_leaf_failure relay-cloud-api "encryption.keyId is required" --set encryption.keyId=
expect_leaf_failure relay-cloud-api "encryption.keyId must contain 1-64 URL-safe characters" --set encryption.keyId=bad/id
expect_leaf_failure relay-cloud-api "must be set together" --set encryption.previousKeyId=ci-0
expect_leaf_failure relay-cloud-api "must be set together" --set secretKeys.previousEncryptionKey=old-key
expect_leaf_failure relay-cloud-api "encryption.previousKeyId must differ" \
  --set encryption.previousKeyId=ci-1 --set secretKeys.previousEncryptionKey=old-key
expect_leaf_failure relay-cloud-api "flows.gcsBucket is required" --set flows.storage=gcs
expect_leaf_failure relay-cloud-api "flows.storage must be postgres or gcs" --set flows.storage=s3
expect_leaf_failure relay-cloud-api "flows.queuePingMs must be an integer from 1000 to 120000" --set flows.queuePingMs=500
expect_leaf_failure relay-cloud-api "telemetry.level must be off, errors, or full" --set telemetry.level=verbose
expect_leaf_failure relay-cloud-api "telemetry.installId is required" --set telemetry.level=errors
expect_leaf_failure relay-cloud-api "secretKeys.telemetryInstallKey is required" \
  --set telemetry.level=errors --set telemetry.installId=inst_abcdefgh12
expect_leaf_failure relay-cloud-api "telemetry.endpoint is required" \
  --set telemetry.level=errors --set telemetry.installId=inst_abcdefgh12 --set secretKeys.telemetryInstallKey=telemetry-install-key
expect_leaf_failure relay-cloud-api "telemetry.endpoint must be an https URL" --set telemetry.endpoint=http://ingest.example.org/
rotation_items=$(helm template ci charts/relay-cloud-api -n ci --no-hooks -f charts/relay-cloud-api/ci/default-values.yaml \
  --set encryption.previousKeyId=ci-0 --set secretKeys.previousEncryptionKey=old-key |
  yq 'select(.kind == "Deployment") | .spec.template.spec.containers[0].env[] | select(.name == "SELFHOST_ENCRYPTION_PREVIOUS_KEY_FILE" or .name == "SELFHOST_ENCRYPTION_PREVIOUS_KEY_ID") | .value')
test "$rotation_items" = "$(printf 'ci-0\n/var/run/agent-relay/secrets/old-key')" \
  || { echo "relay-cloud-api: previous key id/file not rendered ($rotation_items)" >&2; exit 1; }

# The telemetry egress rule (TCP 443) renders only when telemetry is sent:
# level != off and transport=https, under restricted egress.
# https_rules prints how many TCP 443 egress ports the named relay-cloud-api
# NetworkPolicy carries. A failed helm render, a failed yq query or a missing
# policy is an error, never a zero count; only grep's no-match (exit 1) is
# tolerated.
https_rules() { # policy-name helm-args...
  local policy=$1 rendered np ports status=0; shift
  rendered=$(helm template ci charts/relay-cloud-api -n ci --no-hooks -f charts/relay-cloud-api/ci/default-values.yaml \
    --set networkPolicy.allowAllEgress=false --set-json "networkPolicy.additionalEgress=$db_egress" "$@") \
    || { echo "relay-cloud-api: render failed for $policy ($*)" >&2; return 1; }
  np=$(yq "select(.kind == \"NetworkPolicy\" and .metadata.name == \"$policy\")" <<<"$rendered") \
    || { echo "relay-cloud-api: yq failed selecting NetworkPolicy $policy" >&2; return 1; }
  test -n "$np" || { echo "relay-cloud-api: NetworkPolicy $policy was not rendered ($*)" >&2; return 1; }
  ports=$(yq '.spec.egress[] | select(.ports[].port == 443) | .ports[].port' <<<"$np") \
    || { echo "relay-cloud-api: yq failed reading $policy egress" >&2; return 1; }
  grep -c . <<<"$ports" || status=$?
  [ "$status" -le 1 ] || { echo "relay-cloud-api: grep failed counting $policy rules" >&2; return 1; }
}
telemetry_rules() { https_rules ci-relay-cloud-api "$@"; }
expect_rules() { # expected message helm-args...
  local expected=$1 message=$2 count; shift 2
  count=$(telemetry_rules "$@") || exit 1
  test "$count" = "$expected" || { echo "relay-cloud-api: $message (got $count)" >&2; exit 1; }
}
telemetry_on=(--set telemetry.installId=inst_abcdefgh12 --set secretKeys.telemetryInstallKey=telemetry-install-key
  --set telemetry.endpoint=https://agentrelay.com/api/v1/selfhost/telemetry)
expect_rules 0 "telemetry egress rendered with level off"
expect_rules 0 "telemetry egress rendered for transport=file" \
  --set telemetry.level=errors --set telemetry.transport=file "${telemetry_on[@]}"
expect_rules 1 "no telemetry egress rule with level errors over https" --set telemetry.level=errors "${telemetry_on[@]}"
expect_rules 1 "no telemetry egress rule with level full over https" --set telemetry.level=full "${telemetry_on[@]}"
# The migration Job never sends telemetry: its policy must exist and carry no
# TCP 443 rule.
migration_rules=$(https_rules ci-relay-cloud-api-migration --set telemetry.level=full "${telemetry_on[@]}") || exit 1
test "$migration_rules" = 0 \
  || { echo "relay-cloud-api: migration NetworkPolicy allows TCP 443 ($migration_rules rules)" >&2; exit 1; }
# The helper itself must fail closed: a failing render is an error, not 0.
if https_rules ci-relay-cloud-api --set telemetry.level=verbose >/dev/null 2>&1; then
  echo "relay-cloud-api: https_rules treated a failed render as a count" >&2; exit 1
fi
if https_rules ci-relay-cloud-api-absent >/dev/null 2>&1; then
  echo "relay-cloud-api: https_rules treated a missing NetworkPolicy as a count" >&2; exit 1
fi

# Secret keys: every secretKeys value must be distinct, so neither an optional
# runtime key nor a required one can project the migration credential into the
# API pod.
for key in internalToken previousEncryptionKey telemetryInstallKey databaseUrl relayauthApiKey; do
  expect_leaf_failure relay-cloud-api "both name Secret key \"database-migrations-url\"" \
    --set "secretKeys.$key=database-migrations-url"
done
expect_leaf_failure relay-cloud-api "both name Secret key \"selfhost-bootstrap-token\"" \
  --set secretKeys.internalToken=selfhost-bootstrap-token
# Telemetry value shapes.
expect_leaf_failure relay-cloud-api "telemetry.deployment.cluster must be a string, number or boolean" \
  --set-json 'telemetry.deployment={"cluster":{"name":"x"}}'
expect_leaf_failure relay-cloud-api "telemetry.deployment.endpoint must be a short version-like string" \
  --set-json 'telemetry.deployment={"endpoint":"https://internal.example.org"}'
expect_leaf_failure relay-cloud-api "telemetry.deployment.chart is rendered by the chart" \
  --set-json 'telemetry.deployment={"chart":"other"}'
expect_leaf_failure relay-cloud-api "telemetry.deployment key" --set-json 'telemetry.deployment={"1bad":"x"}'
expect_leaf_failure relay-cloud-api "telemetry.probes[].name must be a string" \
  --set-json 'telemetry.probes=[{"name":123,"url":"https://status.example.org/"}]'
expect_leaf_failure relay-cloud-api "at most 63 characters unless it is a dotted name" \
  --set flows.storage=gcs --set "flows.gcsBucket=$(printf 'a%.0s' $(seq 64))"
expect_leaf_failure relay-cloud-api "dotted components must each be 1-63 characters" \
  --set flows.storage=gcs --set "flows.gcsBucket=$(printf 'a%.0s' $(seq 64)).example"
expect_leaf_failure relay-cloud-api "dotted components must each be 1-63 characters" \
  --set flows.storage=gcs --set flows.gcsBucket=bad..bucket
shape=$(helm template ci charts/relay-cloud-api -n ci --no-hooks -f charts/relay-cloud-api/ci/default-values.yaml \
  "${telemetry_on[@]}" --set telemetry.level=errors \
  --set-json 'telemetry.deployment={"region":"us-central1","nodes":3,"gke":true}' \
  --set-json 'telemetry.probes=[{"name":"status-1","url":"https://status.example.org/"}]' |
  yq 'select(.kind == "Deployment") | .spec.template.spec.containers[0].env[] | select(.name == "SELFHOST_TELEMETRY_DEPLOYMENT" or .name == "SELFHOST_TELEMETRY_PROBES") | .value')
grep -q '"region":"us-central1"' <<<"$shape" && grep -q '"nodes":3' <<<"$shape" && grep -qx 'status-1=https://status.example.org/' <<<"$shape" \
  || { echo "relay-cloud-api: telemetry deployment/probes not rendered ($shape)" >&2; exit 1; }
helm template ci charts/relay-cloud-api -n ci --no-hooks -f charts/relay-cloud-api/ci/default-values.yaml \
  --set flows.storage=gcs --set flows.gcsBucket=flows.agent-relay.example.com >/dev/null \
  || { echo "relay-cloud-api: valid dotted GCS bucket rejected" >&2; exit 1; }

expect_leaf_failure relay-cloud-api "ingress.hosts must include the publicUrl host" \
  --set-json 'ingress.hosts=["other.gcp-proof.agentrelay.com"]'

expect_leaf_failure relay-dashboard "runtime.apiBasePath must not be /" --set runtime.apiBasePath=/
expect_leaf_failure relay-dashboard "runtime.loginPath must not be /" --set runtime.loginPath=/
expect_leaf_failure relay-dashboard "runtime.apiBasePath and runtime.loginPath must differ" --set runtime.loginPath=/cloud/api/
expect_leaf_failure relay-dashboard "runtime.loginPath must differ from runtime.appPath" --set runtime.appPath=/app --set runtime.loginPath=/app/

for child in relay-dashboard relay-cloud-api relayhistory; do
  expect_leaf_failure "$child" "podLabels must not set selector label app.kubernetes.io/name" \
    --set 'podLabels.app\.kubernetes\.io/name=custom'
done

# The authority gate applies only when Relaycast itself is deployed.
helm template proof charts/agent-relay -n agent-relay --no-hooks \
  --set components.relaycast=false --set components.relayauth=false \
  --set components.sessionsPipeline=false --set components.relayhistory=false \
  --set components.cloudApi=false --set components.dashboard=false \
  --set relaycast.credentials.authority=relayauth >/dev/null \
  || { echo "authority=relayauth gate fired with components.relaycast=false" >&2; exit 1; }

# Umbrella Ingress backends must name Services the children render, also
# without the profile's fullnameOverrides.
no_override=$(helm template ar charts/agent-relay -n agent-relay --no-hooks "${proof_args[@]}" \
  --set relaycast.fullnameOverride=null --set relayhistory.fullnameOverride=null \
  --set relay-cloud-api.fullnameOverride=null --set relay-dashboard.fullnameOverride=null \
  --set relay-dashboard.api.serviceName=null)
rendered_services=$(yq 'select(.kind == "Service") | .metadata.name' <<<"$no_override" | grep -v '^---$' | sort -u)
for backend in $(yq 'select(.kind == "Ingress") | .spec.rules[].http.paths[].backend.service.name' <<<"$no_override" | grep -v '^---$' | sort -u); do
  grep -qx "$backend" <<<"$rendered_services" \
    || { echo "umbrella Ingress backend $backend has no rendered Service" >&2; exit 1; }
done
if mismatch=$(helm template proof charts/agent-relay -n agent-relay --no-hooks "${proof_args[@]}" \
  --set gkeIngress.backends.history.serviceName=history 2>&1); then
  echo "mismatched gkeIngress backend serviceName rendered successfully" >&2
  exit 1
fi
grep -q 'gkeIngress.backends.history.serviceName=history does not match' <<<"$mismatch" \
  || { echo "backend mismatch failed without the expected error" >&2; exit 1; }

# The customer GCP profile stores Sessions objects in GCS through the native
# adapter (Workload Identity), never AWS S3 or HMAC keys.
gcp_out=$(helm template ar charts/agent-relay -n agent-relay --no-hooks -f charts/agent-relay/values-gcp.yaml)
for w in ar-worker-referee ar-worker-bob-costas ar-worker-hoopdb-indexer ar-alleyoop-ingest; do
  test "$(yq "select(.kind == \"Deployment\" and .metadata.name == \"$w\") |
    .spec.template.spec.containers[0].env[] | select(.name == \"LOCKER_PROVIDER\") | .value" <<<"$gcp_out")" = gcs \
    || { echo "values-gcp.yaml: $w does not select the GCS Locker" >&2; exit 1; }
done
if grep -Eq 'name: "?LOCKER_(ACCESS_KEY_ID|SECRET_ACCESS_KEY)"?$' <<<"$gcp_out"; then
  echo "values-gcp.yaml renders static Locker HMAC credentials" >&2
  exit 1
fi

# The supported-100 overlay sizes Relaycast backups, so it must enable them.
s100=$(helm template ar charts/agent-relay -n agent-relay --no-hooks \
  -f charts/agent-relay/values-gcp.yaml -f charts/agent-relay/values-gcp-supported-100.yaml)
test "$(yq 'select(.kind == "CronJob" and .metadata.name == "relaycast-backup") | .metadata.name' <<<"$s100")" = relaycast-backup \
  || { echo "supported-100 overlay does not render the Relaycast backup CronJob" >&2; exit 1; }
test "$(yq 'select(.kind == "PersistentVolumeClaim" and .metadata.name == "relaycast-backup") | .spec.resources.requests.storage' <<<"$s100")" = 100Gi \
  || { echo "supported-100 overlay backup PVC is not 100Gi" >&2; exit 1; }

# relayauth model B has no default Relaycast URL: the keyring requires one.
if rauth_fail=$(helm template ci charts/relayauth -n ci --no-hooks -f charts/relayauth/ci/default-values.yaml \
  --set secretKeys.relaycastCredentialKeyring=relaycast-credential-keyring \
  --set secretKeys.relaycastInternalSecret=relaycast-internal-secret 2>&1); then
  echo "relayauth model B rendered without relaycast.url" >&2
  exit 1
fi
grep -q 'relaycast.url is required' <<<"$rauth_fail" \
  || { echo "relayauth model B failed without the relaycast.url error" >&2; exit 1; }

echo "agent-relay GCP proof render contract: ok"
