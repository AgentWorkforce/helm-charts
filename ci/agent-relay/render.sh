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

echo "agent-relay GCP proof render contract: ok"
