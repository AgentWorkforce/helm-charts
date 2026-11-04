#!/usr/bin/env bash
#
# Installs Relaycast and Relayfile in durable-actors mode (S3 storage) on the
# EKS substrate made by eks-actors-sandbox.sh. Run each step under the lease:
#
#   pippen sandbox exec actors-proof -- scripts/selfhost/eks-actors-install.sh prereqs
#   pippen sandbox exec actors-proof -- scripts/selfhost/eks-actors-install.sh prepull <dockerconfigjson file>
#   pippen sandbox exec actors-proof -- scripts/selfhost/eks-actors-install.sh install
#   pippen sandbox exec actors-proof -- scripts/selfhost/eks-actors-install.sh actor-env
#   pippen sandbox exec actors-proof -- scripts/selfhost/eks-actors-install.sh status
#   pippen sandbox exec actors-proof -- scripts/selfhost/eks-actors-install.sh uninstall
#
# prereqs: the namespace, a single-replica Postgres for the durable-actors
#   control plane (emptyDir: proof only, it survives control-plane restarts but
#   not a Postgres pod restart), and every Secret with freshly generated values
#   (written to a mode-0700 temp dir, loaded with --from-file and removed;
#   nothing is printed). Re-running keeps existing Secrets.
# prepull: while the images are only in a private registry, a DaemonSet that
#   pulls every image onto every node (it tolerates the actor-host taint) with
#   a short-lived pull Secret, so pods start with IfNotPresent and never need
#   the Secret. The Secret is deleted again by `uninstall`.
# install: helm upgrade --install of charts/agent-relay (CHART_DIR) with
#   values-eks-actors.yaml and the proof values file (VALUES).
# Pod Identity associations come first: eks-actors-sandbox.sh assoc.
#
# Inside a Pippen sandbox the agent-session boundary allows no sts:AssumeRole,
# so the per-actor credentials default cannot work there; the proof values set
# durable-actors.storage.s3.actorCredentials=control-plane (weaker isolation,
# first-party actors only). Outside Pippen, keep the default (assume-role).

set -euo pipefail

: "${PIPPEN_SANDBOX_ACCOUNT_ID:?run under pippen sandbox exec}"
REGION="${AWS_REGION:-us-west-2}"
NAME="${EKS_ACTORS_NAME:-pippen-sbx-actors-proof}"
NS="${EKS_ACTORS_NAMESPACE:-agent-relay}"
RELEASE="${EKS_ACTORS_RELEASE:-agent-relay}"
SANDBOX_NS="${NS}-${RELEASE}"
CHART_DIR="${EKS_ACTORS_CHART_DIR:?path to charts/agent-relay}"
VALUES="${EKS_ACTORS_VALUES:-}"
PG_IMAGE="postgres:16.10-bookworm"

log() { printf '%s %s\n' "$(date -u +%H:%M:%SZ)" "$*" >&2; }

KUBECONFIG_FILE="$(mktemp)"
trap 'rm -f "$KUBECONFIG_FILE"' EXIT
aws --region "$REGION" eks update-kubeconfig --name "$NAME" --kubeconfig "$KUBECONFIG_FILE" >/dev/null
export KUBECONFIG="$KUBECONFIG_FILE"

ensure_secret() {
  local ns="$1" name="$2"; shift 2
  if kubectl -n "$ns" get secret "$name" >/dev/null 2>&1; then log "secret $ns/$name exists"; return; fi
  kubectl -n "$ns" create secret generic "$name" "$@" >/dev/null
  log "secret $ns/$name created"
}

cmd_prereqs() {
  kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  local dir; dir="$(mktemp -d)"; chmod 700 "$dir"
  # shellcheck disable=SC2064
  trap "rm -rf '$dir' '$KUBECONFIG_FILE'" EXIT
  # Values must have no trailing newline: the control plane rejects surrounding whitespace.
  rnd() { openssl rand -hex "$1" | tr -d '\n'; }
  ( umask 077
    rnd 24 > "$dir/pg-password"
    printf 'postgresql://actors:%s@actors-pg.%s.svc:5432/actors?sslmode=disable' "$(cat "$dir/pg-password")" "$NS" > "$dir/postgres-url"
    openssl genpkey -algorithm ED25519 -outform DER | openssl base64 -A | tr -d '\n' > "$dir/jwt-signing-key"
    rnd 32 > "$dir/api-key"
    rnd 32 > "$dir/invoke-api-key"
    rnd 32 > "$dir/internal-secret"
    rnd 32 > "$dir/workspace-bootstrap-secret"
    rnd 32 > "$dir/file-signing-secret"
    printf '{"current":"a","keys":{"a":"%s"}}' "$(rnd 32)" > "$dir/credential-keyring"
    rnd 32 > "$dir/RELAYFILE_JWT_SECRET"
    rnd 32 > "$dir/RELAYFILE_ACTORS_BROKER_TOKEN"
  )
  ensure_secret "$NS" actors-pg --from-file=password="$dir/pg-password"
  ensure_secret "$NS" actors-credentials --from-file=postgres-url="$dir/postgres-url" \
    --from-file=jwt-signing-key="$dir/jwt-signing-key" --from-file=api-key="$dir/api-key" \
    --from-file=invoke-api-key="$dir/invoke-api-key"
  # The gateway's invocation key is the control plane's invoke-only key.
  if ! kubectl -n "$NS" get secret relaycast-durable-actors-invoke >/dev/null 2>&1; then
    kubectl -n "$NS" get secret actors-credentials -o jsonpath='{.data.invoke-api-key}' | base64 -d > "$dir/invoke"
    ensure_secret "$NS" relaycast-durable-actors-invoke --from-file=durable-actors-invoke-key="$dir/invoke"
  fi
  ensure_secret "$NS" relaycast-secrets --from-file=internal-secret="$dir/internal-secret" \
    --from-file=workspace-bootstrap-secret="$dir/workspace-bootstrap-secret" \
    --from-file=credential-keyring="$dir/credential-keyring" \
    --from-file=file-signing-secret="$dir/file-signing-secret"
  ensure_secret "$NS" relayfile-actors --from-file=RELAYFILE_JWT_SECRET="$dir/RELAYFILE_JWT_SECRET" \
    --from-file=RELAYFILE_ACTORS_BROKER_TOKEN="$dir/RELAYFILE_ACTORS_BROKER_TOKEN"
  rm -rf "$dir"
  kubectl -n "$NS" apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Service
metadata: {name: actors-pg}
spec:
  selector: {app: actors-pg}
  ports: [{port: 5432, targetPort: 5432}]
---
apiVersion: apps/v1
kind: StatefulSet
metadata: {name: actors-pg}
spec:
  serviceName: actors-pg
  replicas: 1
  selector: {matchLabels: {app: actors-pg}}
  template:
    metadata: {labels: {app: actors-pg}}
    spec:
      securityContext: {runAsUser: 999, runAsGroup: 999, fsGroup: 999, seccompProfile: {type: RuntimeDefault}}
      containers:
        - name: postgres
          image: ${PG_IMAGE}
          env:
            - {name: POSTGRES_USER, value: actors}
            - {name: POSTGRES_DB, value: actors}
            - {name: PGDATA, value: /var/lib/postgresql/data/pgdata}
            - name: POSTGRES_PASSWORD
              valueFrom: {secretKeyRef: {name: actors-pg, key: password}}
          ports: [{containerPort: 5432}]
          readinessProbe: {exec: {command: [pg_isready, -U, actors, -d, actors]}, periodSeconds: 5}
          resources: {requests: {cpu: 100m, memory: 256Mi}, limits: {memory: 512Mi}}
          securityContext: {allowPrivilegeEscalation: false, capabilities: {drop: [ALL]}}
          volumeMounts: [{name: data, mountPath: /var/lib/postgresql/data}, {name: run, mountPath: /var/run/postgresql}]
      volumes: [{name: data, emptyDir: {}}, {name: run, emptyDir: {}}]
EOF
  # The control plane's NetworkPolicy allows egress to Postgres only where it
  # is told to; this proof keeps Postgres in the release namespace.
  kubectl -n "$NS" rollout status statefulset/actors-pg --timeout=300s >/dev/null
  log "postgres ready"
}

cmd_prepull() {
  local config="${1:?dockerconfigjson file}"
  kubectl -n "$NS" create secret generic image-pull --type=kubernetes.io/dockerconfigjson \
    --from-file=.dockerconfigjson="$config" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  local images; images="$(helm template "$RELEASE" "$CHART_DIR" -n "$NS" \
    -f "$CHART_DIR/values-eks-actors.yaml" ${VALUES:+-f "$VALUES"} \
    | grep -oE '(image|value): "?[a-z0-9.-]+\.[a-z]+/[^" ]+@sha256:[0-9a-f]{64}' \
    | sed -E 's/^(image|value): "?//' | sort -u)"
  local init="" i=0
  for image in $images; do
    init+="        - {name: pull-$i, image: \"$image\", command: [sh, -c, 'exit 0'], resources: {requests: {cpu: 10m, memory: 16Mi}}}"$'\n'
    i=$((i + 1))
  done
  kubectl -n "$NS" apply -f - >/dev/null <<EOF
apiVersion: apps/v1
kind: DaemonSet
metadata: {name: image-prepull}
spec:
  selector: {matchLabels: {app: image-prepull}}
  template:
    metadata: {labels: {app: image-prepull}}
    spec:
      imagePullSecrets: [{name: image-pull}]
      automountServiceAccountToken: false
      tolerations: [{key: durable-actors/actor-host, operator: Exists, effect: NoSchedule}]
      initContainers:
${init}      containers:
        - {name: pause, image: "registry.k8s.io/pause:3.10", resources: {requests: {cpu: 1m, memory: 8Mi}}}
EOF
  kubectl -n "$NS" rollout status daemonset/image-prepull --timeout=900s >/dev/null
  log "pre-pulled $i images onto every node"
}

cmd_install() {
  helm upgrade --install "$RELEASE" "$CHART_DIR" -n "$NS" \
    -f "$CHART_DIR/values-eks-actors.yaml" ${VALUES:+-f "$VALUES"} --wait=false >/dev/null
  log "helm release $RELEASE installed"
}

# The Workspace actor's env Secret lives in the sandbox namespace, which the
# durable-actors chart creates (and deletes on uninstall), so it follows install.
cmd_actor_env() {
  if kubectl -n "$SANDBOX_NS" get secret relaycast-actor-env >/dev/null 2>&1; then log "relaycast-actor-env exists"; return; fi
  local dir; dir="$(mktemp -d)"; chmod 700 "$dir"
  ( umask 077
    printf '%s' "${RELAYCAST_PUBLIC_URL:-https://cast.aws-actors.invalid}" > "$dir/RELAYCAST_PUBLIC_URL"
    kubectl -n "$NS" get secret relaycast-secrets -o jsonpath='{.data.file-signing-secret}' | base64 -d > "$dir/RELAYCAST_FILE_SIGNING_SECRET"
    kubectl -n "$NS" get secret relaycast-secrets -o jsonpath='{.data.internal-secret}' | base64 -d > "$dir/RELAYCAST_INTERNAL_SECRET"
  )
  ensure_secret "$SANDBOX_NS" relaycast-actor-env --from-file=RELAYCAST_PUBLIC_URL="$dir/RELAYCAST_PUBLIC_URL" \
    --from-file=RELAYCAST_FILE_SIGNING_SECRET="$dir/RELAYCAST_FILE_SIGNING_SECRET" \
    --from-file=RELAYCAST_INTERNAL_SECRET="$dir/RELAYCAST_INTERNAL_SECRET"
  rm -rf "$dir"
}

cmd_status() {
  kubectl -n "$NS" get pods -o wide
  kubectl -n "$SANDBOX_NS" get pods -o wide 2>/dev/null || true
  helm -n "$NS" status "$RELEASE" 2>/dev/null | head -8 || true
}

cmd_uninstall() {
  helm -n "$NS" uninstall "$RELEASE" --wait 2>/dev/null || true
  kubectl delete namespace "$SANDBOX_NS" --wait=true --ignore-not-found >/dev/null
  kubectl delete namespace "$NS" --wait=true --ignore-not-found >/dev/null
  log "release, sandbox namespace and namespace (Secrets, pull Secret, Postgres) deleted"
}

case "${1:-}" in
  prereqs) cmd_prereqs ;;
  prepull) shift; cmd_prepull "$@" ;;
  install) cmd_install ;;
  actor-env) cmd_actor_env ;;
  status) cmd_status ;;
  uninstall) cmd_uninstall ;;
  *) echo "usage: $0 prereqs|prepull <dockerconfigjson>|install|actor-env|status|uninstall" >&2; exit 2 ;;
esac
