#!/usr/bin/env bash
# Render every pinned dependency in deps/ with its values and fail if it needs
# Helm hooks for correctness (hooks never run under Alchemy's
# `helm template --no-hooks`). Helm test hooks are allowed: dropping them is
# harmless. Versions come from deps/pins.txt.
set -euo pipefail
cd "$(dirname "$0")/../.."
helm repo add cnpg https://cloudnative-pg.github.io/charts >/dev/null 2>&1 || true
helm repo add minio https://charts.min.io/ >/dev/null 2>&1 || true
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts >/dev/null 2>&1 || true
helm repo update cnpg minio open-telemetry >/dev/null
fail=0
while read -r name chart version values; do
  echo "--- deps: $name ($chart $version)"
  out=$(helm template "$name" "$chart" --version "$version" -f "deps/$values" --namespace ci --include-crds) \
    || { echo "::error::$name: render failed"; fail=1; continue; }
  hooks=$(grep -E '^\s*"?helm\.sh/hook"?\s*:' <<<"$out" | grep -vE ':\s*"?test(-success)?"?\s*$' || true)
  if [ -n "$hooks" ]; then
    echo "$hooks"
    echo "::error::$name: renders non-test Helm hooks with deps/$values; they never run under --no-hooks"
    fail=1
  fi
done < <(grep -vE '^\s*(#|$)' deps/pins.txt)
exit $fail
