#!/usr/bin/env bash
# kind smoke test for the 96bulls umbrella chart: the whole pipeline as ONE
# release, installed the way Alchemy's Kubernetes.HelmChart does it
# (`helm template --no-hooks` + server-side apply). The CloudNativePG operator
# is a prerequisite, installed from deps/pins.txt.
# Usage: ci/96bulls-umbrella/smoke.sh [image]
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
CLUSTER=${CLUSTER:-96bulls-smoke}
NS=${NS:-96bulls-umbrella}
IMAGE=${1:-ghcr.io/agentworkforce/96bulls-services:kind}
CTX="kind-$CLUSTER"
K="kubectl --context $CTX -n $NS"

kind get clusters | grep -qx "$CLUSTER" || kind create cluster --name "$CLUSTER" --wait 120s
kind load docker-image "$IMAGE" --name "$CLUSTER"

# CloudNativePG operator (cluster-wide prerequisite).
# Every repository the operator and the umbrella's Chart.lock need.
helm repo add cnpg https://cloudnative-pg.github.io/charts >/dev/null 2>&1 || true
helm repo add minio https://charts.min.io/ >/dev/null 2>&1 || true
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts >/dev/null 2>&1 || true
helm repo update cnpg minio open-telemetry >/dev/null
read -r _ chart version values < <(grep '^cnpg-operator ' "$ROOT/deps/pins.txt")
kubectl --context "$CTX" create namespace cnpg-system --dry-run=client -o yaml | kubectl --context "$CTX" apply -f -
helm template cnpg "$chart" --version "$version" -f "$ROOT/deps/$values" --namespace cnpg-system --no-hooks --include-crds \
  | kubectl --context "$CTX" -n cnpg-system apply --server-side --force-conflicts --field-manager=smoke -f -
kubectl --context "$CTX" -n cnpg-system rollout status deploy --timeout=300s

kubectl --context "$CTX" create namespace "$NS" --dry-run=client -o yaml | kubectl --context "$CTX" apply -f -
# The one Secret the umbrella needs (kind-only throwaway values).
SUMMARY_MASTER_KEYS=$($K get secret 96bulls-locker -o jsonpath='{.data.SUMMARY_MASTER_KEYS}' 2>/dev/null | base64 -d || true)
SUMMARY_MASTER_KEYS=${SUMMARY_MASTER_KEYS:-"kind1:$(openssl rand -hex 32)"}
printf %s "$SUMMARY_MASTER_KEYS" | $K create secret generic 96bulls-locker --from-literal=rootUser=locker --from-literal=rootPassword=locker-kind-only \
  --from-file=SUMMARY_MASTER_KEYS=/dev/stdin \
  --from-literal=JWKS_JSON='{"keys":[]}' --dry-run=client -o yaml | $K apply -f -
unset SUMMARY_MASTER_KEYS

helm dependency build "$ROOT/charts/96bulls" >/dev/null
IMG_REPO=${IMAGE%:*} IMG_TAG=${IMAGE##*:}
helm template bulls "$ROOT/charts/96bulls" --namespace "$NS" --no-hooks --include-crds \
    -f "$ROOT/charts/96bulls/ci/kind-values.yaml" \
    --set global.imageRegistry= \
    --set "worker.image.repository=$IMG_REPO" --set "worker.image.tag=$IMG_TAG" --set worker.image.digest= \
    --set "alleyoop.image.repository=$IMG_REPO" --set "alleyoop.image.tag=$IMG_TAG" --set alleyoop.image.digest= \
  | $K apply --server-side --field-manager=smoke -f -

$K wait cluster.postgresql.cnpg.io/hoopdb --for=condition=Ready --timeout=600s
$K wait --for=condition=complete job -l app.kubernetes.io/component=hoopdb-migrate --timeout=600s
$K wait --for=condition=complete job -l app.kubernetes.io/component=locker-init --timeout=300s
$K rollout status deploy --timeout=300s
$K get cluster.postgresql.cnpg.io,jobs,deploy
echo "smoke: OK"
