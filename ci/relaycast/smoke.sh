#!/usr/bin/env bash
# kind smoke test for charts/relaycast-cloud, installed the way Alchemy's
# Kubernetes.HelmChart does it: `helm template --no-hooks` + server-side apply.
# No Helm release, no hooks. Usage: ci/relaycast/smoke.sh [image]
#
# The engine runs on SQLite today, so no deps/ (Postgres, MinIO, OTel) are
# installed. Build the image from a relaycast checkout first, e.g.:
#   docker build -t ghcr.io/agentworkforce/relaycast:kind .
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
CLUSTER=${CLUSTER:-relaycast-smoke}
NS=${NS:-relaycast}
IMAGE=${1:-ghcr.io/agentworkforce/relaycast:kind}
K="kubectl --context kind-$CLUSTER -n $NS"
apply() { # release chart [helm args...]
  local rel=$1 chart=$2; shift 2
  helm template "$rel" "$chart" --namespace "$NS" --no-hooks --include-crds "$@" \
    | kubectl --context "kind-$CLUSTER" -n "$NS" apply --server-side --field-manager=smoke -f -
}

kind get clusters | grep -qx "$CLUSTER" || kind create cluster --name "$CLUSTER" --wait 120s
kind load docker-image "$IMAGE" --name "$CLUSTER"
kubectl --context "kind-$CLUSTER" create namespace "$NS" --dry-run=client -o yaml | kubectl --context "kind-$CLUSTER" apply -f -

# Secrets (kind-only throwaway value).
$K create secret generic relaycast \
  --from-literal=RELAYCAST_WORKSPACE_BOOTSTRAP_SECRET=relaycast-kind-only \
  --dry-run=client -o yaml | $K apply -f -

# Chart under test. The image under test (argument 1) overrides the values file.
IMG_REPO=${IMAGE%:*} IMG_TAG=${IMAGE##*:}
IMG_ARGS=(--set global.imageRegistry= --set "image.repository=$IMG_REPO" --set "image.tag=$IMG_TAG")
apply rc "$ROOT/charts/relaycast-cloud" -f "$ROOT/charts/relaycast-cloud/ci/kind-values.yaml" \
  --set existingSecret=relaycast "${IMG_ARGS[@]}"

$K rollout status deploy --timeout=300s

# Functional check: health, then an anonymous workspace create (open by default).
SVC=$($K get svc -l app.kubernetes.io/instance=rc -o jsonpath='{.items[0].metadata.name}')
$K port-forward "svc/$SVC" 18787:8787 >/dev/null 2>&1 &
PF=$!
trap 'kill $PF 2>/dev/null || true' EXIT
for _ in $(seq 1 30); do curl -fsS http://127.0.0.1:18787/health >/dev/null 2>&1 && break; sleep 1; done
curl -fsS http://127.0.0.1:18787/health | grep -q '"ok":true'
curl -fsS -X POST http://127.0.0.1:18787/v1/workspaces \
  -H 'content-type: application/json' -d '{"name":"smoke"}' | grep -q '"api_key":"rk_live_'

$K get deploy,pods,pvc -o wide
echo "smoke: OK"
