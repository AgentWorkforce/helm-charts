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
done
exit $fail
