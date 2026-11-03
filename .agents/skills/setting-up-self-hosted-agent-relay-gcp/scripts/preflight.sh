#!/usr/bin/env bash
set -euo pipefail

required_vars=(GCP_PROJECT_ID GCP_PROJECT_NUMBER GCP_REGION GKE_CLUSTER BASE_DOMAIN)
required_commands=(gcloud kubectl helm kubeconform jq yq node openssl)

die() {
  printf 'preflight: %s\n' "$*" >&2
  exit 1
}

for name in "${required_vars[@]}"; do
  test -n "${!name:-}" || die "$name is required"
done

for command_name in "${required_commands[@]}"; do
  command -v "$command_name" >/dev/null 2>&1 ||
    die "$command_name is required"
done

case "$BASE_DOMAIN" in
  *.*) ;;
  *) die "BASE_DOMAIN must be a public multi-label DNS name" ;;
esac
case "$BASE_DOMAIN" in
  localhost|*.localhost|*.local|*[!A-Za-z0-9.-]*)
    die "BASE_DOMAIN is not a permitted public DNS name"
    ;;
esac

gcloud auth print-access-token >/dev/null 2>&1 ||
  die "Google authentication is unavailable; run gcloud auth login"

active_project=$(gcloud config get-value project 2>/dev/null)
test "$active_project" = "$GCP_PROJECT_ID" ||
  die "active project is $active_project, expected $GCP_PROJECT_ID"

actual_project_number=$(
  gcloud projects describe "$GCP_PROJECT_ID" --format='value(projectNumber)'
)
test "$actual_project_number" = "$GCP_PROJECT_NUMBER" ||
  die "project number is $actual_project_number, expected $GCP_PROJECT_NUMBER"

# Kube-context identity: the exact gcloud-generated context name, which must
# be both the pinned KUBE_CONTEXT and the current context, and whose API
# server must be an endpoint of the approved cluster according to GKE itself
# (a renamed or edited context pointing elsewhere fails here).
expected_context="gke_${GCP_PROJECT_ID}_${GCP_REGION}_${GKE_CLUSTER}"
test "${KUBE_CONTEXT:-}" = "$expected_context" ||
  die "KUBE_CONTEXT must be exported as $expected_context (got '${KUBE_CONTEXT:-}')"
current_context=$(kubectl config current-context 2>/dev/null || true)
test "$current_context" = "$expected_context" ||
  die "current kube context is '$current_context', expected $expected_context"

context_server=$(
  kubectl config view --raw \
    -o "jsonpath={.clusters[?(@.name==\"$(
      kubectl config view -o "jsonpath={.contexts[?(@.name==\"$expected_context\")].context.cluster}"
    )\")].cluster.server}"
)
test -n "$context_server" || die "kube context $expected_context has no API server"

cluster_endpoints=$(
  gcloud container clusters describe "$GKE_CLUSTER" \
    --project "$GCP_PROJECT_ID" --location "$GCP_REGION" --format=json |
    jq -r '[.endpoint,
            .privateClusterConfig.privateEndpoint,
            .controlPlaneEndpointsConfig.dnsEndpointConfig.endpoint]
           | map(select(. != null and . != "")) | .[]'
) || die "cannot describe GKE cluster $GKE_CLUSTER in $GCP_PROJECT_ID/$GCP_REGION"
server_matches=false
while IFS= read -r endpoint; do
  test -n "$endpoint" || continue
  if test "$context_server" = "https://$endpoint"; then
    server_matches=true
  fi
done <<<"$cluster_endpoints"
test "$server_matches" = true ||
  die "kube context $expected_context server $context_server is not an endpoint of cluster $GKE_CLUSTER"

for host in "$BASE_DOMAIN" "api.$BASE_DOMAIN" "cast.$BASE_DOMAIN" "history.$BASE_DOMAIN"; do
  case "$host" in
    *..*|.*|*.) die "invalid host $host" ;;
  esac
done

printf 'preflight: project=%s number=%s region=%s cluster=%s context=%s server=%s domain=%s\n' \
  "$GCP_PROJECT_ID" "$GCP_PROJECT_NUMBER" "$GCP_REGION" "$GKE_CLUSTER" \
  "$KUBE_CONTEXT" "$context_server" "$BASE_DOMAIN"
printf 'preflight: OK\n'
