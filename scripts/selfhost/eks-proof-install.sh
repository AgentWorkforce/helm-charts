#!/usr/bin/env bash
#
# Installs the agent-relay chart on the EKS proof substrate made by
# eks-proof-sandbox.sh, then exposes it through ALB Ingresses. Run each step
# under the Pippen lease (kubectl authenticates through `aws eks get-token`):
#
#   pippen sandbox exec aws-proof -- scripts/selfhost/eks-proof-install.sh prereqs
#   pippen sandbox exec aws-proof -- scripts/selfhost/eks-proof-install.sh install
#   pippen sandbox exec aws-proof -- scripts/selfhost/eks-proof-install.sh bootstrap-org
#   pippen sandbox exec aws-proof -- scripts/selfhost/eks-proof-install.sh status
#   pippen sandbox exec aws-proof -- scripts/selfhost/eks-proof-install.sh uninstall
#
# prereqs: the CloudNativePG operator, a CNPG cluster for the control API
#   database (HoopDb gets its own CNPG cluster from the chart), and the release
#   Secret with freshly generated values. Secret values are generated into a
#   mode-0700 temp dir, loaded with --from-file and removed; nothing is
#   printed. Re-running keeps an existing Secret.
# install: helm install/upgrade of the published chart with values-eks.yaml
#   plus a generated proof overlay (bucket, ECR digest, tenant, VPC CIDR), the
#   three ALB Ingresses (dashboard, api, cast), then a second upgrade with the
#   ALB hostnames as the public origins.
# bootstrap-org: the control plane's one-time installation organization
#   (POST /api/v1/organizations with the bootstrap token, from inside the API
#   pod so the token never leaves it). Idempotent: skips when one exists.
# uninstall: Ingresses first (so the ALBs go), helm uninstall, the CNPG
#   clusters and their PVCs, the operator, the namespace.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
: "${PIPPEN_SANDBOX_ACCOUNT_ID:?run under pippen sandbox exec}"
ACCOUNT="$PIPPEN_SANDBOX_ACCOUNT_ID"
REGION="${AWS_REGION:-us-west-2}"
NAME="${EKS_PROOF_NAME:-pippen-sbx-eks-proof}"
NS="${EKS_PROOF_NAMESPACE:-agent-relay}"
RELEASE="${EKS_PROOF_RELEASE:-agent-relay}"
CHART="${EKS_PROOF_CHART:-oci://ghcr.io/agentworkforce/charts/agent-relay}"
CHART_VERSION="${EKS_PROOF_CHART_VERSION:-0.3.4}"
SECRET="${EKS_PROOF_SECRET:-agent-relay-eks-proof}"
ORG_ID="${EKS_PROOF_ORG_ID:-org_eks_proof}"
VPC_CIDR="${EKS_PROOF_VPC_CIDR:-10.42.0.0/16}"
BUCKET="${NAME}-${ACCOUNT}"
# sessions-pipeline main 7d7229b, the ECR copy in sessions-dev (500268966557)
# whose repository policy lets the sandbox account pull.
SERVICES_REPO="${EKS_PROOF_SERVICES_REPO:-500268966557.dkr.ecr.us-west-2.amazonaws.com/96bulls-services}"
SERVICES_DIGEST="${EKS_PROOF_SERVICES_DIGEST:-sha256:5bb6075240afa02a1b1797a81c07bffa029954eac7803d702ecba20db35d4db9}"
CNPG_CHART_VERSION="${EKS_PROOF_CNPG_CHART_VERSION:-0.26.1}"
PG_IMAGE="ghcr.io/cloudnative-pg/postgresql:17-standard-trixie@sha256:ed6923f9ba2399cf9070379a353c710c29ced8a294be73986a2c3dae7e599ce3"
STATE_DIR="${EKS_PROOF_STATE_DIR:-$ROOT/.eks-proof}"

log() { printf '%s %s\n' "$(date -u +%H:%M:%SZ)" "$*" >&2; }

KUBECONFIG_FILE="$(mktemp)"
trap 'rm -f "$KUBECONFIG_FILE"' EXIT
aws --region "$REGION" eks update-kubeconfig --name "$NAME" --kubeconfig "$KUBECONFIG_FILE" >/dev/null
export KUBECONFIG="$KUBECONFIG_FILE"
mkdir -p "$STATE_DIR"

cmd_prereqs() {
  kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  log "CloudNativePG operator (chart $CNPG_CHART_VERSION)"
  helm upgrade --install cnpg cloudnative-pg --repo https://cloudnative-pg.github.io/charts \
    --version "$CNPG_CHART_VERSION" --namespace cnpg-system --create-namespace --wait --timeout 10m >/dev/null

  if ! kubectl -n "$NS" get secret "$SECRET" >/dev/null 2>&1; then
    log "generate Secret $SECRET (values never printed)"
    local d; d="$(mktemp -d)"; chmod 700 "$d"
    (
      umask 077; cd "$d"
      openssl rand -hex 32 > relaycast-internal-secret
      openssl rand -hex 32 > relaycast-workspace-bootstrap-secret
      openssl rand -hex 32 > relayauth-internal-secret
      openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:3072 -out relayauth-signing-key.pem 2>/dev/null
      printf 'rak_%s' "$(openssl rand -hex 24)" > relayauth-bootstrap-api-key
      cp relayauth-bootstrap-api-key relayauth-api-key
      openssl rand -hex 32 > selfhost-bootstrap-token
      openssl rand -hex 32 > selfhost-encryption-key
      printf 'eks1:%s' "$(openssl rand -hex 32)" > SUMMARY_MASTER_KEYS
      openssl rand -hex 24 > control-api-runtime-password
      # The control API database: the CNPG app user owns it and runs the
      # migrations; the runtime role gets only what the migrations grant.
      printf 'postgresql://control_api_runtime:%s@control-api-pg-rw.%s.svc:5432/control_api?sslmode=disable' \
        "$(cat control-api-runtime-password)" "$NS" > database-url
    )
    kubectl -n "$NS" create secret generic control-api-runtime --type kubernetes.io/basic-auth \
      --from-literal=username=control_api_runtime --from-file=password="$d/control-api-runtime-password" >/dev/null
    kubectl -n "$NS" label secret control-api-runtime cnpg.io/reload=true >/dev/null
    kubectl -n "$NS" create secret generic "$SECRET" \
      --from-file="$d/relaycast-internal-secret" --from-file="$d/relaycast-workspace-bootstrap-secret" \
      --from-file="$d/relayauth-internal-secret" --from-file="$d/relayauth-signing-key.pem" \
      --from-file="$d/relayauth-bootstrap-api-key" --from-file="$d/relayauth-api-key" \
      --from-file="$d/selfhost-bootstrap-token" --from-file="$d/selfhost-encryption-key" \
      --from-file="$d/SUMMARY_MASTER_KEYS" --from-file="$d/database-url" >/dev/null
    rm -rf "$d"
  fi

  log "CNPG cluster control-api-pg"
  kubectl apply -f - >/dev/null <<EOF
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: control-api-pg
  namespace: ${NS}
spec:
  instances: 1
  imageName: ${PG_IMAGE}
  storage:
    size: 5Gi
  bootstrap:
    initdb:
      database: control_api
      owner: control_api
  managed:
    roles:
      - name: control_api_runtime
        ensure: present
        login: true
        passwordSecret:
          name: control-api-runtime
EOF
  kubectl -n "$NS" wait cluster/control-api-pg --for=condition=Ready --timeout=15m >/dev/null
  # database-migrations-url = the CNPG app user's URI (owner of control_api).
  if ! kubectl -n "$NS" get secret "$SECRET" -o jsonpath='{.data.database-migrations-url}' | grep -q .; then
    local uri
    uri="$(kubectl -n "$NS" get secret control-api-pg-app -o jsonpath='{.data.uri}' | base64 -d)"
    kubectl -n "$NS" patch secret "$SECRET" --type merge \
      -p "{\"stringData\":{\"database-migrations-url\":\"${uri}?sslmode=disable\"}}" >/dev/null
    unset uri
  fi
  log "prereqs ready"
}

# proof_overlay <dashboard> <api> <cast>: the non-secret proof overlay.
proof_overlay() {
  local dash="$1" api="$2" cast="$3"
  cat > "$STATE_DIR/values-eks-proof.yaml" <<EOF
# Generated by eks-proof-install.sh: proof-specific, non-secret.
global:
  tenant:
    orgId: ${ORG_ID}
relaycast:
  baseUrl: ${cast}
  existingSecret: ${SECRET}
  resources: { requests: { cpu: 50m, memory: 128Mi } }
  networkPolicy:
    ingressFrom:
      - podSelector: {}
      - ipBlock: { cidr: ${VPC_CIDR} }
relayauth:
  existingSecret: ${SECRET}
sessions-pipeline:
  worker:
    image: { repository: ${SERVICES_REPO}, digest: "${SERVICES_DIGEST}" }
    existingSecret: ${SECRET}
    summaryEncryption: { existingSecret: ${SECRET} }
    locker: { bucket: ${BUCKET}, region: ${REGION} }
  alleyoop:
    image: { repository: ${SERVICES_REPO}, digest: "${SERVICES_DIGEST}" }
    existingSecret: ${SECRET}
    locker: { bucket: ${BUCKET}, region: ${REGION} }
    auth: { historyOrigin: https://history-unavailable.eks-proof.agentrelay.com }
  privilegedSql:
    sqlImage: { repository: ${SERVICES_REPO}, digest: "${SERVICES_DIGEST}" }
relay-cloud-api:
  existingSecret: ${SECRET}
  publicUrl: ${api}
  dashboardUrl: ${dash}/
  services:
    relaycastPublicUrl: ${cast}
    relayhistoryPublicUrl: https://history-unavailable.eks-proof.agentrelay.com
  networkPolicy:
    ingressFrom:
      - podSelector: {}
      - ipBlock: { cidr: ${VPC_CIDR} }
relay-dashboard:
  runtime:
    publicUrl: ${dash}
  networkPolicy:
    ingressFrom:
      - podSelector: {}
      - ipBlock: { cidr: ${VPC_CIDR} }
EOF
}

helm_apply() {
  helm upgrade --install "$RELEASE" "$CHART" --version "$CHART_VERSION" --namespace "$NS" \
    -f "$ROOT/charts/agent-relay/values-eks.yaml" -f "$STATE_DIR/values-eks-proof.yaml" \
    --wait --timeout 20m
}

alb_host() {
  kubectl -n "$NS" get ingress "$1" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true
}

cmd_install() {
  local dash api cast
  dash="$(alb_host agent-relay-dashboard)"; api="$(alb_host agent-relay-api)"; cast="$(alb_host agent-relay-cast)"
  if [[ -z "$dash" || -z "$api" || -z "$cast" ]]; then
    # First pass: placeholder origins, so the Services exist for the ALBs.
    proof_overlay https://dashboard-pending.eks-proof.agentrelay.com https://api-pending.eks-proof.agentrelay.com \
      https://cast-pending.eks-proof.agentrelay.com
    log "helm install (pass 1, placeholder origins)"
    helm_apply
    "$HERE/eks-alb-ingress.sh" "$NS" | kubectl apply -f -
    log "waiting for ALB hostnames"
    for _ in $(seq 1 60); do
      dash="$(alb_host agent-relay-dashboard)"; api="$(alb_host agent-relay-api)"; cast="$(alb_host agent-relay-cast)"
      [[ -n "$dash" && -n "$api" && -n "$cast" ]] && break
      sleep 10
    done
    [[ -n "$dash" && -n "$api" && -n "$cast" ]] || { log "ALB hostnames did not appear"; exit 1; }
  fi
  dash="${dash#http://}"; api="${api#http://}"; cast="${cast#http://}"
  # The charts accept only https public origins and an ALB hostname cannot
  # get an ACM certificate, so the proof names https://<ALB hostname> (the
  # validation passes) while the ALBs listen on HTTP only. Clients in the
  # proof use http://<ALB hostname>. Production: a DNS name and ACM cert.
  dash="https://${dash#https://}"; api="https://${api#https://}"; cast="https://${cast#https://}"
  proof_overlay "$dash" "$api" "$cast"
  log "helm upgrade (pass 2): dashboard=$dash api=$api cast=$cast"
  helm_apply
  cmd_status
}

cmd_bootstrap_org() {
  local owner="${EKS_PROOF_OWNER_EMAIL:-owner@eks-proof.agentrelay.com}"
  kubectl -n "$NS" exec -i deploy/relay-cloud-api -- node --input-type=module - "$owner" <<'JS'
import { readFileSync } from "node:fs";
const token = readFileSync("/var/run/agent-relay/secrets/selfhost-bootstrap-token", "utf8").trim();
const api = "http://127.0.0.1:3000/api/v1/organizations";
const headers = { authorization: `Bearer ${token}`, "content-type": "application/json" };
const list = await (await fetch(api, { headers })).json();
if ((list.organizations ?? []).length > 0) {
  console.log(`organization exists: ${list.organizations[0].id}`);
} else {
  const res = await fetch(api, { method: "POST", headers,
    body: JSON.stringify({ name: "EKS Proof", ownerEmail: process.argv[2], ownerName: "EKS Proof Owner" }) });
  const body = await res.json();
  console.log(`create organization: status=${res.status} id=${body.id ?? body.organization?.id ?? "-"} error=${body.error?.code ?? body.error ?? "-"}`);
  if (!res.ok) process.exit(1);
}
JS
}

cmd_status() {
  helm -n "$NS" status "$RELEASE" 2>/dev/null | sed -n '1,8p' || true
  kubectl -n "$NS" get pods,ingress,cluster.postgresql.cnpg.io -o wide 2>/dev/null || true
}

cmd_uninstall() {
  kubectl -n "$NS" delete ingress --all --wait=true --timeout=10m || true
  helm -n "$NS" uninstall "$RELEASE" --wait --timeout 10m || true
  kubectl -n "$NS" delete cluster.postgresql.cnpg.io --all --wait=true --timeout=10m || true
  kubectl -n "$NS" delete pvc --all --wait=true --timeout=10m || true
  helm -n cnpg-system uninstall cnpg --wait --timeout 10m || true
  kubectl delete namespace "$NS" cnpg-system --wait=true --timeout=10m || true
  kubectl get pv 2>/dev/null || true
}

case "${1:-}" in
  prereqs) cmd_prereqs ;;
  install) cmd_install ;;
  bootstrap-org) cmd_bootstrap_org ;;
  status) cmd_status ;;
  uninstall) cmd_uninstall ;;
  *) echo "usage: $0 prereqs|install|bootstrap-org|status|uninstall" >&2; exit 2 ;;
esac
