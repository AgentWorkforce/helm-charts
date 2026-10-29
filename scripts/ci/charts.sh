#!/usr/bin/env bash
# Chart checks shared by CI and local runs.
#
#   scripts/ci/charts.sh static [chart...]   lint, hook ban, determinism, kubeconform
#   scripts/ci/charts.sh dryrun [chart...]   server-side dry-run apply on a cluster
#
# Every chart is checked once per charts/<chart>/ci/*-values.yaml (or once with
# defaults when it has none). Renders use `helm template --no-hooks`, the way
# Alchemy's Kubernetes.HelmChart installs, so a chart that only works through
# Helm hooks fails here.
set -euo pipefail
cd "$(dirname "$0")/../.."

mode=${1:?usage: charts.sh static|dryrun [chart...]}; shift
charts=("$@")
[ ${#charts[@]} -gt 0 ] || charts=($(ls -d charts/*/ | xargs -n1 basename))
fail=0
err() { echo "::error::$*"; fail=1; }

render() { # chart valuesfile [extra helm args]
  local chart=$1 v=$2 args=(); shift 2
  [ -n "$v" ] && args=(-f "$v")
  helm template ci "charts/$chart" --namespace ci --no-hooks --include-crds "${args[@]}" "$@"
}

expect_render_failure() { # chart valuesfile label expected-error [extra helm args]
  local chart=$1 v=$2 label=$3 expected=$4 output; shift 4
  echo "--- static: $chart (reject $label)"
  if output=$(render "$chart" "$v" "$@" 2>&1); then
    err "$chart: $label unexpectedly rendered successfully"
  elif ! grep -Fq "$expected" <<<"$output"; then
    err "$chart: $label failed without expected error: $expected"
    echo "$output"
  fi
}

for chart in "${charts[@]}"; do
  [ -f "charts/$chart/Chart.yaml" ] || { err "$chart: no Chart.yaml"; continue; }
  if [ -f "charts/$chart/Chart.lock" ] || grep -q '^dependencies:' "charts/$chart/Chart.yaml"; then
    # helm dependency build only resolves https repositories that are added.
    for repo in $(sed -n 's/^ *repository: *\(https:.*\)/\1/p' "charts/$chart/Chart.yaml" | sort -u); do
      helm repo add "dep-$(echo "$repo" | md5sum | cut -c1-8)" "$repo" >/dev/null 2>&1 || true
    done
    helm dependency build "charts/$chart" >/dev/null || { err "$chart: helm dependency build failed"; continue; }
  fi
  values=(charts/"$chart"/ci/*-values.yaml)
  [ -e "${values[0]}" ] || values=("")
  for v in "${values[@]}"; do
    label="$chart${v:+ ($(basename "$v"))}"
    echo "--- $mode: $label"
    case $mode in
      static)
        args=(); [ -n "$v" ] && args=(-f "$v")
        helm lint --strict "charts/$chart" "${args[@]}" >/dev/null || { helm lint --strict "charts/$chart" "${args[@]}"; err "$label: helm lint --strict failed"; continue; }
        out=$(render "$chart" "$v") || { err "$label: render failed"; continue; }
        if [[ "$v" == *pod-identity-values.yaml ]] && grep -Eq '^[[:space:]]*- name: LOCKER_(ACCESS_KEY_ID|SECRET_ACCESS_KEY)[[:space:]]*$' <<<"$out"; then
          err "$label: podIdentity mode renders a static Locker credential environment variable"
        fi
        # --no-hooks drops hooked objects, so ban hooks on a full render.
        # Helm test hooks are allowed (e.g. in third-party subcharts): dropping them is harmless.
        if helm template ci "charts/$chart" --namespace ci "${args[@]}" | grep -E '^\s*"?helm\.sh/hook"?\s*:' | grep -vE ':\s*"?test(-success)?"?\s*$'; then
          err "$label: renders a helm.sh/hook annotation. Hooks never run under Alchemy (helm template --no-hooks); use a plain Job instead"
        fi
        if ! diff -q <(echo "$out") <(render "$chart" "$v") >/dev/null; then
          err "$label: render is not deterministic (randAlphaNum/lookup/now?); every render would look like drift"
        fi
        kubeconform -strict -summary -ignore-missing-schemas -kubernetes-version "${KUBE_VERSION:-1.33.0}" <<<"$out" || err "$label: kubeconform failed"
        ;;
      dryrun)
        render "$chart" "$v" | kubectl apply --server-side --dry-run=server --field-manager=ci -n ci -f - >/dev/null \
          || err "$label: server-side dry-run apply failed"
        ;;
      *) echo "unknown mode $mode" >&2; exit 2 ;;
    esac
  done
  if [ "$mode" = static ]; then
    case $chart in
      96bulls-worker)
        v=charts/96bulls-worker/ci/pod-identity-values.yaml
        expect_render_failure "$chart" "$v" "unknown credential mode" "locker.credentials.mode must be secret or podIdentity" --set locker.credentials.mode=invalid
        expect_render_failure "$chart" "$v" "missing database Secret" "hoopdb.existingSecret or existingSecret is required for HOOPDB_URL" --set hoopdb.existingSecret=
        expect_render_failure "$chart" "$v" "secret mode without endpoint" "locker.endpoint is required when locker.credentials.mode=secret" --set locker.credentials.mode=secret --set existingSecret=96bulls
        ;;
      alleyoop)
        v=charts/alleyoop/ci/pod-identity-values.yaml
        expect_render_failure "$chart" "$v" "unknown credential mode" "locker.credentials.mode must be secret or podIdentity" --set locker.credentials.mode=invalid
        expect_render_failure "$chart" "$v" "missing database Secret" "hoopdb.existingSecret or existingSecret is required for HOOPDB_URL" --set hoopdb.existingSecret=
        expect_render_failure "$chart" "$v" "secret mode without endpoint" "locker.endpoint is required when locker.credentials.mode=secret" --set locker.credentials.mode=secret --set existingSecret=96bulls
        expect_render_failure "$chart" "$v" "local JWKS without Secret" "existingSecret is required when auth.localJwks=true" --set auth.jwksUrl= --set auth.localJwks=true
        ;;
      relayauth)
        v=charts/relayauth/ci/default-values.yaml
        expect_render_failure "$chart" "$v" "mutable image" "image.digest is required" --set image.digest=
        expect_render_failure "$chart" "$v" "malformed digest" "image.digest must be sha256:<64 lowercase hex characters>" --set image.digest=sha256:abc
        expect_render_failure "$chart" "$v" "missing external Secret" "existingSecret is required" --set existingSecret=
        expect_render_failure "$chart" "$v" "unsafe Secret key path" "secretKeys.signingKey must be a Kubernetes Secret data key" --set-string secretKeys.signingKey=../key.pem
        expect_render_failure "$chart" "$v" "multiple SQLite writers" "replicaCount must be 1" --set replicaCount=2
        expect_render_failure "$chart" "$v" "JWKS ingress without host" "jwksIngress.enabled=true requires at least one host" --set jwksIngress.enabled=true
        ;;
    esac
  fi
done
exit $fail
