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

context=$(kubectl config current-context)
case "$context" in
  *"$GCP_PROJECT_ID"*"$GCP_REGION"*"$GKE_CLUSTER"*) ;;
  *) die "kube context $context does not name the approved project/region/cluster" ;;
esac

for host in "$BASE_DOMAIN" "api.$BASE_DOMAIN" "cast.$BASE_DOMAIN" "history.$BASE_DOMAIN"; do
  case "$host" in
    *..*|.*|*.) die "invalid host $host" ;;
  esac
done

printf 'preflight: project=%s number=%s region=%s cluster=%s domain=%s\n' \
  "$GCP_PROJECT_ID" "$GCP_PROJECT_NUMBER" "$GCP_REGION" "$GKE_CLUSTER" "$BASE_DOMAIN"
printf 'preflight: OK\n'
