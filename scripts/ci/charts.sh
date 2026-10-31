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
        if [ "$chart" = "96bulls-worker" ]; then
          summary_file_refs=$(grep -Ec '^[[:space:]]*- name: SUMMARY_MASTER_KEYS_FILE[[:space:]]*$' <<<"$out" || true)
          summary_value_refs=$(grep -Ec '^[[:space:]]*- name: SUMMARY_MASTER_KEYS[[:space:]]*$' <<<"$out" || true)
          [ "$summary_file_refs" -eq 1 ] || err "$label: SUMMARY_MASTER_KEYS_FILE must be injected exactly once (Bob Costas only), found $summary_file_refs"
          [ "$summary_value_refs" -eq 0 ] || err "$label: SUMMARY_MASTER_KEYS must never be injected as an environment variable, found $summary_value_refs"
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
        expect_render_failure "$chart" "$v" "missing summary Secret" "summaryEncryption.existingSecret or existingSecret is required when bob-costas is enabled" --set summaryEncryption.existingSecret=
        expect_render_failure "$chart" "$v" "duplicate summary key env" "configure summaryEncryption instead of components.bob-costas.env" --set-json 'components.bob-costas.env=[{"name":"SUMMARY_MASTER_KEYS","value":"not-a-real-key"}]'
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
        expect_render_failure "$chart" "$v" "public JWKS with private discovery URL" "jwksIngress.enabled=true requires an explicit externally reachable baseUrl" --set jwksIngress.enabled=true --set jwksIngress.hosts[0]=auth.example.com
        expect_render_failure "$chart" "$v" "blocked JWKS ingress" "jwksIngress with networkPolicy requires networkPolicy.ingressFrom" --set jwksIngress.enabled=true --set jwksIngress.hosts[0]=auth.example.com --set baseUrl=https://auth.example.com --set networkPolicy.enabled=true
        ;;
      relaycast)
        v=charts/relaycast/ci/default-values.yaml
        expect_render_failure "$chart" "$v" "mutable image" "image.digest is required" --set image.digest=
        expect_render_failure "$chart" "$v" "malformed digest" "image.digest must be sha256:<64 lowercase hex characters>" --set image.digest=sha256:abc
        expect_render_failure "$chart" "$v" "missing origin" "baseUrl is required" --set baseUrl=
        expect_render_failure "$chart" "$v" "plaintext public origin" "baseUrl must be an HTTPS origin" --set baseUrl=http://relay.example.com
        expect_render_failure "$chart" "$v" "origin with path" "baseUrl must be an HTTPS origin" --set baseUrl=https://relay.example.com/relay
        expect_render_failure "$chart" "$v" "single-label origin" "baseUrl must be an HTTPS origin" --set baseUrl=https://localhost
        expect_render_failure "$chart" "$v" "IP-literal origin" "baseUrl must be an HTTPS origin" --set baseUrl=https://127.0.0.1
        expect_render_failure "$chart" "$v" "origin with credentials" "baseUrl must be an HTTPS origin" --set baseUrl=https://user:pass@relay.example.com
        expect_render_failure "$chart" "$v" "special-use local origin" "baseUrl must not use the special-use .local namespace" --set baseUrl=https://relay.example.local
        expect_render_failure "$chart" "$v" "special-use localhost origin" "baseUrl must not use the special-use .localhost namespace" --set baseUrl=https://relay.localhost
        expect_render_failure "$chart" "$v" "invalid public port" "baseUrl port must be between 1 and 65535" --set baseUrl=https://relay.example.com:65536
        expect_render_failure "$chart" "$v" "insecure origin with path" "baseUrl must be an origin" --set allowInsecureBaseUrl=true --set baseUrl=http://relaycast.relaycast.svc:8787/x
        expect_render_failure "$chart" "$v" "missing Secret" "existingSecret is required" --set existingSecret=
        expect_render_failure "$chart" "$v" "unsafe Secret key path" "secretKeys.internalSecret must be a Kubernetes Secret data key" --set-string secretKeys.internalSecret=../key
        expect_render_failure "$chart" "$v" "non-boolean public create" "publicWorkspaceCreate must be true or false" --set-string publicWorkspaceCreate=yes
        expect_render_failure "$chart" "$v" "direct public Service" "service.type must be ClusterIP" --set service.type=LoadBalancer
        expect_render_failure "$chart" "$v" "multiple SQLite writers" "replicaCount must be 1" --set replicaCount=2
        expect_render_failure "$chart" "$v" "zero SQLite writers" "replicaCount must be 1" --set replicaCount=0
        expect_render_failure "$chart" "$v" "unreleased HA backend" "runtime.backend must be sqlite" --set runtime.backend=armadillo
        expect_render_failure "$chart" "$v" "unsafe persistence access mode" "persistence.accessMode must be ReadWriteOnce or ReadWriteOncePod" --set persistence.accessMode=ReadWriteMany
        expect_render_failure "$chart" "$v" "secret via extraEnv" "RELAYCAST_INTERNAL_SECRET is managed by structured chart values" --set-json 'extraEnv=[{"name":"RELAYCAST_INTERNAL_SECRET","value":"not-a-real-secret"}]'
        expect_render_failure "$chart" "$v" "bootstrap secret via extraEnv" "RELAYCAST_WORKSPACE_BOOTSTRAP_SECRET is managed by structured chart values" --set-json 'extraEnv=[{"name":"RELAYCAST_WORKSPACE_BOOTSTRAP_SECRET","value":"not-a-real-secret"}]'
        expect_render_failure "$chart" "$v" "public create via extraEnv" "RELAYCAST_PUBLIC_WORKSPACE_CREATE is managed by structured chart values" --set-json 'extraEnv=[{"name":"RELAYCAST_PUBLIC_WORKSPACE_CREATE","value":"true"}]'
        expect_render_failure "$chart" "$v" "reserved database path" "RELAYCAST_DB_PATH is managed by structured chart values" --set-json 'extraEnv=[{"name":"RELAYCAST_DB_PATH","value":"/tmp/other.db"}]'
        expect_render_failure "$chart" "$v" "zero message retention" "retention.messageTtlDays must be a positive integer" --set retention.messageTtlDays=0
        expect_render_failure "$chart" "$v" "negative message retention" "retention.messageTtlDays must be a positive integer" --set retention.messageTtlDays=-1
        expect_render_failure "$chart" "$v" "boolean message retention" "retention.messageTtlDays must be a positive integer" --set retention.messageTtlDays=true
        expect_render_failure "$chart" "$v" "zero mailbox TTL" "mailbox.ttlMs must be a positive integer" --set mailbox.ttlMs=0
        expect_render_failure "$chart" "$v" "boolean mailbox TTL" "mailbox.ttlMs must be a positive integer" --set mailbox.ttlMs=true
        expect_render_failure "$chart" "$v" "zero mailbox depth" "mailbox.depthCap must be a positive integer" --set mailbox.depthCap=0
        expect_render_failure "$chart" "$v" "boolean mailbox depth" "mailbox.depthCap must be a positive integer" --set mailbox.depthCap=true
        v=charts/relaycast/ci/full-values.yaml
        expect_render_failure "$chart" "$v" "ingress with public create" "ingress.enabled requires publicWorkspaceCreate=false" --set publicWorkspaceCreate=true
        expect_render_failure "$chart" "$v" "ingress with insecure origin" "ingress.enabled requires an HTTPS public baseUrl" --set allowInsecureBaseUrl=true
        expect_render_failure "$chart" "$v" "ingress without hosts" "ingress.enabled=true requires at least one host" --set-json 'ingress.hosts=[]'
        expect_render_failure "$chart" "$v" "ingress host mismatch" "ingress.hosts must include the baseUrl host" --set-json 'ingress.hosts=["other.example.com"]'
        expect_render_failure "$chart" "$v" "ingress blocked by NetworkPolicy" "ingress with networkPolicy requires networkPolicy.ingressFrom" --set-json 'networkPolicy.ingressFrom=[]'
        expect_render_failure "$chart" "$v" "backup on ReadWriteOncePod" "backup.enabled requires persistence.accessMode=ReadWriteOnce" --set persistence.accessMode=ReadWriteOncePod
        expect_render_failure "$chart" "$v" "zero backup retention" "backup.keep must be a positive integer" --set backup.keep=0
        # Rendered-contract checks: secrets only as files, edge denials routed
        # to the endpoint-less Service, public create off.
        out=$(render "$chart" "$v")
        grep -q 'name: RELAYCAST_INTERNAL_SECRET_FILE' <<<"$out" || err "$chart: internal secret is not passed as a file"
        grep -q 'name: RELAYCAST_WORKSPACE_BOOTSTRAP_SECRET_FILE' <<<"$out" || err "$chart: bootstrap secret is not passed as a file"
        ! grep -Eq 'name: RELAYCAST_(INTERNAL|WORKSPACE_BOOTSTRAP)_SECRET$' <<<"$out" || err "$chart: a secret is rendered as a plain environment variable"
        [ "$(yq 'select(.kind == "Deployment") | .spec.template.spec.containers[0].env[] | select(.name == "RELAYCAST_PUBLIC_WORKSPACE_CREATE") | .value' <<<"$out")" = false ] \
          || err "$chart: public workspace create is not off"
        for p in /internal /v1/workspaces /v1/workspaces/; do
          [ "$(yq "select(.kind == \"Ingress\") | .spec.rules[0].http.paths[] | select(.path == \"$p\") | .backend.service.name" <<<"$out")" = ci-relaycast-deny ] \
            || err "$chart: ingress path $p is not routed to the deny Service"
        done
        [ "$(yq 'select(.kind == "Service" and .metadata.name == "ci-relaycast-deny") | (.spec | has("selector") | not)' <<<"$out")" = true ] \
          || err "$chart: the deny Service must have no selector"
        [ "$(yq 'select(.kind == "CronJob") | .spec.jobTemplate.spec.template.metadata.labels["app.kubernetes.io/name"]' <<<"$out")" = relaycast-backup ] \
          || err "$chart: backup pods must not carry the Service selector labels"
        ;;
    esac
  fi
done
exit $fail
