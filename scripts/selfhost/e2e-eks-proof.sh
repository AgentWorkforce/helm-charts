#!/usr/bin/env bash
#
# End-to-end proof of the agent-relay suite on AWS EKS (values-eks.yaml, the
# layout eks-proof-install.sh creates). It runs the same cases as the GKE
# proof (e2e-gcp-proof.sh) with the ALB edge (--edge alb), then adds the
# AWS-specific checks:
#
#   EKS|PASS|FAIL|<check>|<non-secret detail>
#     eks.pod_identity       worker/alleyoop ServiceAccounts have Pod Identity
#                            associations
#     eks.s3_locker_*        Pod Identity -> S3: put/head/get/list/delete through
#                            the services image's Locker adapter, in the alleyoop
#                            pod (e2e-eks-proof-s3.ts)
#     eks.alb_targets        every ALB target group has healthy targets
#     eks.cnpg               the CNPG clusters are healthy
#
# Run it under the Pippen lease, so kubectl and aws use the session role:
#
#   pippen sandbox exec aws-proof -- scripts/selfhost/e2e-eks-proof.sh [e2e-gcp-proof.sh options]
#
# Options it sets itself: --context (a temporary kubeconfig), --namespace,
# --sessions-namespace (the same namespace: the umbrella installs the
# Sessions Pipeline next to the rest), --secret, --edge alb and the origins
# (read from the three ALB Ingresses), and --relayauth-url (RelayAuth runs in
# the release namespace under the umbrella). Any other option is passed through,
# e.g. --skip-flows, --allow-known-gap NAME or --no-cleanup.
#
# --eks-checks-only runs only the EKS checks (no e2e-gcp-proof.sh cases).
#
# Exit status: e2e-gcp-proof.sh's status, or 1 if an EKS check failed.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REGION="${AWS_REGION:-us-west-2}"
NAME="${EKS_PROOF_NAME:-pippen-sbx-eks-proof}"
NS="${EKS_PROOF_NAMESPACE:-agent-relay}"
RELEASE="${EKS_PROOF_RELEASE:-agent-relay}"
SECRET="${EKS_PROOF_SECRET:-agent-relay-eks-proof}"
ACCOUNT="${PIPPEN_SANDBOX_ACCOUNT_ID:-$(aws sts get-caller-identity --query Account --output text)}"
BUCKET="${EKS_PROOF_BUCKET:-${NAME}-${ACCOUNT}}"

KUBECONFIG_FILE="$(mktemp)"
trap 'rm -f "$KUBECONFIG_FILE"' EXIT
aws --region "$REGION" eks update-kubeconfig --name "$NAME" --alias eks-proof \
  --kubeconfig "$KUBECONFIG_FILE" >/dev/null || { echo "E2E_RESULT=FAIL"; echo "reason: no kubeconfig for $NAME"; exit 1; }
export KUBECONFIG="$KUBECONFIG_FILE"
K=(kubectl --context eks-proof -n "$NS")

origin() { # ingress -> http://<alb hostname>
  local h
  h="$("${K[@]}" get ingress "$1" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)"
  [[ -n "$h" ]] && printf 'http://%s' "$h"
}
DASHBOARD="$(origin agent-relay-dashboard)"
API="$(origin agent-relay-api)"
CAST="$(origin agent-relay-cast)"
if [[ -z "$DASHBOARD" || -z "$API" || -z "$CAST" ]]; then
  echo "E2E_RESULT=FAIL"; echo "reason: the ALB Ingresses have no hostnames (eks-alb-ingress.sh applied?)"; exit 1
fi
# RelayHistory is not part of the EKS profile yet (no release image); the
# origin is the chart value, so its public checks fail with no backend.
HISTORY="$("${K[@]}" get deploy relay-cloud-api \
  -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="RELAYHISTORY_PUBLIC_URL")].value}' 2>/dev/null)"
HISTORY="${HISTORY:-http://history.unavailable.invalid}"

rc=0
EKS_ONLY=false
if [[ "${1:-}" == --eks-checks-only ]]; then EKS_ONLY=true; shift; fi
$EKS_ONLY || bash "$HERE/e2e-gcp-proof.sh" --context eks-proof --namespace "$NS" --sessions-namespace "$NS" \
  --secret "$SECRET" --edge alb --dashboard-origin "$DASHBOARD" --api-origin "$API" \
  --cast-origin "$CAST" --history-origin "${HISTORY%/}" --relayauth-url http://relayauth:8787 "$@" || rc=$?

printf '\n== EKS checks (%s)\n' "$(date -u +%FT%TZ)"
EKS_FAILS=0
eks() { # result check detail
  printf 'EKS|%s|%s|%s\n' "$1" "$2" "$3"
  [[ "$1" == FAIL ]] && EKS_FAILS=$((EKS_FAILS + 1))
  return 0
}

assoc="$(aws --region "$REGION" eks list-pod-identity-associations --cluster-name "$NAME" --namespace "$NS" \
  --query 'associations[].serviceAccount' --output text 2>/dev/null | tr '\t' ' ')"
missing=""
for sa in "${RELEASE}-worker" "${RELEASE}-alleyoop"; do
  [[ " $assoc " == *" $sa "* ]] || missing+="$sa "
done
[[ -z "$missing" ]] && eks PASS eks.pod_identity "associations=${assoc}" || eks FAIL eks.pod_identity "missing=${missing% }"

alleyoop="$("${K[@]}" get pod -l app.kubernetes.io/name=alleyoop --field-selector=status.phase=Running \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
s3_out=""
[[ -n "$alleyoop" ]] && s3_out="$("${K[@]}" exec -i "$alleyoop" -- sh -c \
  'umask 077; cat > /tmp/e2e-eks-proof-s3.ts && cd /app && bun run /tmp/e2e-eks-proof-s3.ts; rm -f /tmp/e2e-eks-proof-s3.ts' \
  <"$HERE/e2e-eks-proof-s3.ts" 2>/dev/null)"
while IFS='|' read -r _ result check detail; do eks "$result" "$check" "$detail"; done < <(grep '^EKS|' <<<"$s3_out")
grep -q '^EKS|PASS|eks.s3_locker_roundtrip|' <<<"$s3_out" || eks FAIL eks.s3_locker_roundtrip "no PASS from the probe (pod=${alleyoop:-none} bucket=$BUCKET)"

unhealthy=""
healthy=0
for lb in $(aws --region "$REGION" elbv2 describe-load-balancers \
  --query "LoadBalancers[?contains(DNSName, \`${DASHBOARD#http://}\`) || contains(DNSName, \`${API#http://}\`) || contains(DNSName, \`${CAST#http://}\`)].LoadBalancerArn" --output text 2>/dev/null); do
  for tg in $(aws --region "$REGION" elbv2 describe-target-groups --load-balancer-arn "$lb" --query 'TargetGroups[].TargetGroupArn' --output text); do
    states="$(aws --region "$REGION" elbv2 describe-target-health --target-group-arn "$tg" --query 'TargetHealthDescriptions[].TargetHealth.State' --output text | tr '\t' ' ')"
    if [[ " $states " == *" healthy "* ]]; then healthy=$((healthy + 1)); else unhealthy+="${tg##*/}=${states:-none} "; fi
  done
done
[[ -z "$unhealthy" && $healthy -gt 0 ]] && eks PASS eks.alb_targets "healthy_target_groups=$healthy" ||
  eks FAIL eks.alb_targets "healthy=$healthy unhealthy=${unhealthy% }"

cnpg="$("${K[@]}" get cluster.postgresql.cnpg.io -o jsonpath='{range .items[*]}{.metadata.name}={.status.phase}{";"}{end}' 2>/dev/null)"
cnpg_ok=false
if [[ -n "$cnpg" ]]; then
  cnpg_ok=true
  IFS=';' read -r -a cnpg_items <<<"$cnpg"
  for item in "${cnpg_items[@]}"; do
    [[ -z "$item" || "${item#*=}" == "Cluster in healthy state" ]] || cnpg_ok=false
  done
fi
$cnpg_ok && eks PASS eks.cnpg "${cnpg%;}" || eks FAIL eks.cnpg "${cnpg%;}"

if ((EKS_FAILS)); then
  printf 'EKS_RESULT=FAIL\n'
  ((rc == 0)) && rc=1
else
  printf 'EKS_RESULT=PASS\n'
fi
exit "$rc"
