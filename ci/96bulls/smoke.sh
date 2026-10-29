#!/usr/bin/env bash
# kind smoke test for the 96Bulls charts, installed the way Alchemy's
# Kubernetes.HelmChart does it: `helm template --no-hooks` + server-side apply.
# No Helm release, no hooks. Usage: ci/96bulls/smoke.sh [image]
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
CLUSTER=${CLUSTER:-96bulls-smoke}
NS=${NS:-96bulls}
IMAGE=${1:-ghcr.io/agentworkforce/96bulls-services:kind}
K="kubectl --context kind-$CLUSTER -n $NS"
apply() { # release chart [helm args...]
  local rel=$1 chart=$2; shift 2
  helm template "$rel" "$chart" --namespace "$NS" --no-hooks --include-crds "$@" \
    | kubectl --context "kind-$CLUSTER" -n "$NS" apply --server-side --field-manager=smoke -f -
}

kind get clusters | grep -qx "$CLUSTER" || kind create cluster --name "$CLUSTER" --wait 120s
kind load docker-image "$IMAGE" --name "$CLUSTER"
kubectl --context "kind-$CLUSTER" create namespace "$NS" --dry-run=client -o yaml | kubectl --context "kind-$CLUSTER" apply -f -

helm repo add minio https://charts.min.io >/dev/null 2>&1 || true
helm repo add otel https://open-telemetry.github.io/opentelemetry-helm-charts >/dev/null 2>&1 || true
helm repo update minio otel >/dev/null

# Secrets (kind-only throwaway values).
$K create secret generic locker-root --from-literal=rootUser=locker --from-literal=rootPassword=locker-kind-only \
  --dry-run=client -o yaml | $K apply -f -
$K create secret generic 96bulls \
  --from-literal=HOOPDB_URL=postgres://hoop:hoop-kind-only@hoopdb:5432/hoopdb \
  --from-literal=LOCKER_ACCESS_KEY_ID=locker --from-literal=LOCKER_SECRET_ACCESS_KEY=locker-kind-only \
  --from-literal=JWKS_JSON='{"keys":[]}' --dry-run=client -o yaml | $K apply -f -

# Dependencies.
$K apply --server-side --field-manager=smoke -f "$ROOT/ci/96bulls/postgres.yaml"
apply locker minio/minio --version 5.4.0 -f "$ROOT/ci/96bulls/minio-values.yaml"
apply otel otel/opentelemetry-collector --version 0.178.0 -f "$ROOT/ci/96bulls/otel-values.yaml"

# Charts under test, all at once: workloads must tolerate any apply order.
# The image under test (argument 1) overrides the values file.
IMG_REPO=${IMAGE%:*} IMG_TAG=${IMAGE##*:}
IMG_ARGS=(--set global.imageRegistry= --set "image.repository=$IMG_REPO" --set "image.tag=$IMG_TAG")
apply bulls "$ROOT/charts/96bulls-worker" -f "$ROOT/ci/96bulls/values.yaml" "${IMG_ARGS[@]}"
apply oop "$ROOT/charts/alleyoop" -f "$ROOT/ci/96bulls/values.yaml" "${IMG_ARGS[@]}"

$K wait --for=condition=complete job -l app.kubernetes.io/component=hoopdb-migrate --timeout=300s
$K wait --for=condition=complete job -l app.kubernetes.io/component=locker-init --timeout=300s
$K rollout status deploy --timeout=300s
$K get jobs,deploy,pods -o wide
echo "smoke: OK"
