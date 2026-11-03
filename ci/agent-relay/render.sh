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

# The supported-100 overlay sizes Relaycast backups, so it must enable them.
s100=$(helm template ar charts/agent-relay -n agent-relay --no-hooks \
  -f charts/agent-relay/values-gcp.yaml -f charts/agent-relay/values-gcp-supported-100.yaml)
test "$(yq 'select(.kind == "CronJob" and .metadata.name == "relaycast-backup") | .metadata.name' <<<"$s100")" = relaycast-backup \
  || { echo "supported-100 overlay does not render the Relaycast backup CronJob" >&2; exit 1; }
test "$(yq 'select(.kind == "PersistentVolumeClaim" and .metadata.name == "relaycast-backup") | .spec.resources.requests.storage' <<<"$s100")" = 100Gi \
  || { echo "supported-100 overlay backup PVC is not 100Gi" >&2; exit 1; }

echo "agent-relay GCP proof render contract: ok"
