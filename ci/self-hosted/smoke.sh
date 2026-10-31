#!/usr/bin/env bash
# Zero-state kind evidence for charts/self-hosted with the Relaycast add-on on.
# Proves, against the published 12.2.1-selfhost.1 digest:
#   - a default-off install creates no Relaycast workload
#   - an enabled install from an empty namespace becomes Ready
#   - anonymous workspace create is refused; /internal without a bearer is not a create
#   - secrets are mounted read-only as files
#   - authenticated register/read (ci/relaycast/smoke.mjs full)
#   - state survives a pod restart
#   - a pod outside the namespace cannot reach the Service; one inside can
#   - backup + ci/relaycast/restore.sh rolls back a post-backup message
#
# Creates kind cluster $CLUSTER when CREATE_CLUSTER=1 (default name
# relaycast-oss-zero). Refuses the aws-proof contexts and kind-96bulls-e2e.
# Does not install into namespace relaycast-proof.
# Deletes the cluster it created after a passing run. KEEP_CLUSTER=1 keeps it.
set -euo pipefail
export TMPDIR="${TMPDIR:-$HOME/.agent-tmp}"
mkdir -p "$TMPDIR"
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
HERE="$ROOT/ci/self-hosted"
NS=${NS:-relaycast-oss}
OFF_NS=${OFF_NS:-relaycast-oss-off}
OUT_NS=${OUT_NS:-relaycast-oss-out}
RELEASE=${RELEASE:-selfhosted}
PORT=${PORT:-18790}
CLUSTER=${CLUSTER:-relaycast-oss-zero}
NP_MANIFEST=${NP_MANIFEST:-https://raw.githubusercontent.com/kubernetes-sigs/kube-network-policies/v1.1.2/install.yaml}
IMAGE=ghcr.io/agentworkforce/relaycast-self-host@sha256:a05732ad4f3614d057bb1460df40a30e3a9297c8930bfdda6d4e3d6dc9f41762
CHART="$ROOT/charts/self-hosted"
WORK=$(mktemp -d "$TMPDIR/relaycast-oss.XXXXXX")
chmod 700 "$WORK"
PF_PID=
CREATED=0
PREV_CTX=$(kubectl config current-context 2>/dev/null || true)

case "$NS:$OFF_NS:$OUT_NS" in
  *relaycast-proof*) echo "refusing namespace relaycast-proof" >&2; exit 2 ;;
esac
case "$CLUSTER" in
  96bulls-e2e|aws-proof|""|relaycast-proof) echo "refusing cluster name $CLUSTER" >&2; exit 2 ;;
esac
if [ -n "${FROM_VERSION:-}" ]; then
  echo "this smoke is zero-state only; unset FROM_VERSION" >&2
  exit 2
fi
case "$(helm version --template '{{.Version}}')" in
  v4.*) ;;
  *) echo "need Helm 4 (CI is v4.3.1)" >&2; exit 2 ;;
esac

restore_context() {
  if [ -n "$PREV_CTX" ]; then
    kubectl config use-context "$PREV_CTX" >/dev/null 2>&1 || true
  fi
}
on_exit() {
  local rc=$?
  [ -n "$PF_PID" ] && kill "$PF_PID" 2>/dev/null || true
  if [ "$rc" -ne 0 ] && [ "$CREATED" = 1 ]; then
    kubectl --context "kind-$CLUSTER" -n "$NS" get pods,svc,netpol,pvc,job,cronjob -o wide >&2 || true
    kubectl --context "kind-$CLUSTER" -n "$NS" logs "deploy/${RELEASE}-relaycast" --tail=60 >&2 || true
  fi
  if [ "$CREATED" = 1 ] && { [ "$rc" -eq 0 ] || [ "${KEEP_CLUSTER:-0}" != 1 ]; }; then
    kind delete cluster --name "$CLUSTER" >/dev/null 2>&1 || true
  fi
  restore_context
  rm -rf "$WORK"
  exit "$rc"
}
trap on_exit EXIT

refuse_context() {
  case "$1" in
    aws-proof|sessions-dev|kind-96bulls-e2e|arn:aws:*)
      echo "refusing to install on context $1" >&2
      exit 2
      ;;
  esac
}

if [ "${CREATE_CLUSTER:-0}" = 1 ]; then
  if kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
    kind delete cluster --name "$CLUSTER" >/dev/null
  fi
  kind create cluster --name "$CLUSTER" --wait 180s >/dev/null
  CREATED=1
  kubectl config use-context "kind-$CLUSTER" >/dev/null
else
  refuse_context "$(kubectl config current-context)"
  [ "$(kubectl config current-context)" = "kind-$CLUSTER" ] || {
    echo "context is not kind-$CLUSTER" >&2
    exit 2
  }
fi
refuse_context "$(kubectl config current-context)"
[ "$(kubectl config current-context)" = "kind-$CLUSTER" ] || {
  echo "context is not kind-$CLUSTER" >&2
  exit 2
}

K() { kubectl -n "$1" "$@"; }
SEL="app.kubernetes.io/name=relaycast,app.kubernetes.io/instance=$RELEASE"

helm dependency build "$CHART" >/dev/null

echo "--- default-off install"
kubectl create namespace "$OFF_NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
helm install "$RELEASE" "$CHART" -n "$OFF_NS" -f "$CHART/ci/default-values.yaml" --wait --timeout 2m >/dev/null
off_work=$(kubectl -n "$OFF_NS" get deploy,sts,ds,job,cronjob,pvc,netpol,ingress,svc --no-headers 2>/dev/null || true)
[ -z "$off_work" ] && echo "PASS default-off install has no workload" || { echo "FAIL default-off rendered workloads: $off_work"; exit 1; }
kubectl -n "$OFF_NS" get configmap "$RELEASE-self-hosted-contract" >/dev/null
echo "PASS default-off contract ConfigMap"

echo "--- enabled install from empty namespace"
umask 077
openssl rand -hex 32 >"$WORK/internal"
openssl rand -hex 32 >"$WORK/bootstrap"
kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl -n "$NS" create secret generic relaycast-secrets \
  --from-file=internal-secret="$WORK/internal" \
  --from-file=workspace-bootstrap-secret="$WORK/bootstrap" \
  --dry-run=client -o yaml | kubectl -n "$NS" apply -f - >/dev/null
helm install "$RELEASE" "$CHART" -n "$NS" \
  -f "$CHART/ci/kubernetes-values.yaml" \
  --set relaycast.backup.keep=2 \
  --wait --timeout 8m >/dev/null
kubectl -n "$NS" rollout status "deploy/${RELEASE}-relaycast" --timeout=180s >/dev/null
ready=$(kubectl -n "$NS" get deploy "${RELEASE}-relaycast" -o jsonpath='{.status.readyReplicas}')
[ "$ready" = 1 ] && echo "PASS enabled install ready" || { echo "FAIL ready replicas $ready"; exit 1; }
[ "$(kubectl -n "$NS" get deploy "${RELEASE}-relaycast" -o jsonpath='{.spec.strategy.type}')" = Recreate ] \
  && echo "PASS strategy Recreate" || { echo "FAIL strategy"; exit 1; }
[ "$(kubectl -n "$NS" get deploy "${RELEASE}-relaycast" -o jsonpath='{.spec.template.spec.containers[0].image}')" = "$IMAGE" ] \
  && echo "PASS image digest pinned" || { echo "FAIL image pin"; exit 1; }

echo "--- secret files"
kubectl -n "$NS" exec "deploy/${RELEASE}-relaycast" -- node -e '
  const fs = require("fs");
  function check(envName, fileName) {
    const p = process.env[envName];
    if (p !== "/run/secrets/relaycast/" + fileName) {
      console.error("bad path", envName, p);
      process.exit(1);
    }
    const st = fs.statSync(p);
    if ((st.mode & 0o222) !== 0) {
      console.error("writable secret", p, st.mode.toString(8));
      process.exit(1);
    }
    if (fs.readFileSync(p, "utf8").trim().length < 32) process.exit(1);
  }
  if (process.env.RELAYCAST_INTERNAL_SECRET || process.env.RELAYCAST_WORKSPACE_BOOTSTRAP_SECRET) {
    console.error("plain secret env is set");
    process.exit(1);
  }
  check("RELAYCAST_INTERNAL_SECRET_FILE", "internal-secret");
  check("RELAYCAST_WORKSPACE_BOOTSTRAP_SECRET_FILE", "workspace-bootstrap-secret");
  const mounts = fs.readFileSync("/proc/mounts", "utf8").split("\n").filter((l) => l.includes(" /run/secrets/relaycast "));
  if (!mounts.some((l) => l.split(" ")[3].split(",").includes("ro"))) {
    console.error("secret mount is not read-only");
    process.exit(1);
  }
'
echo "PASS secret files mounted read-only"

echo "--- network policy enforcement"
kubectl apply -f "$NP_MANIFEST" >/dev/null
kubectl -n kube-system rollout status ds/kube-network-policies --timeout=300s >/dev/null
# Give the queue a moment to attach to pods that already exist.
sleep 5

client_pod() { # ns name script-file
  local ns=$1 name=$2 script=$3
  kubectl -n "$ns" delete pod "$name" --ignore-not-found --wait=true >/dev/null
  kubectl -n "$ns" apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: $name
  labels:
    app.kubernetes.io/name: relaycast-smoke-client
spec:
  restartPolicy: Never
  automountServiceAccountToken: false
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
    runAsGroup: 1000
  containers:
    - name: client
      image: $IMAGE
      imagePullPolicy: IfNotPresent
      command: ["node", "/script/check.mjs"]
      securityContext:
        allowPrivilegeEscalation: false
        capabilities: {drop: [ALL]}
        readOnlyRootFilesystem: true
      volumeMounts:
        - {name: script, mountPath: /script, readOnly: true}
        - {name: tmp, mountPath: /tmp}
  volumes:
    - name: script
      configMap:
        name: $name
    - name: tmp
      emptyDir: {sizeLimit: 32Mi}
EOF
}

wait_exit() { # ns name -> prints exit code
  local ns=$1 name=$2 i code
  for i in $(seq 60); do
    code=$(kubectl -n "$ns" get pod "$name" -o jsonpath='{.status.containerStatuses[0].state.terminated.exitCode}' 2>/dev/null || true)
    if [ -n "$code" ]; then
      printf '%s' "$code"
      return 0
    fi
    sleep 2
  done
  kubectl -n "$ns" describe pod "$name" >&2 || true
  return 1
}

cat >"$WORK/allow.mjs" <<EOF
const url = "http://${RELEASE}-relaycast.${NS}.svc:8787/health";
const ac = new AbortController();
setTimeout(() => ac.abort(), 8000);
fetch(url, { signal: ac.signal }).then((r) => {
  if (r.status !== 200) process.exit(1);
  process.exit(0);
}).catch(() => process.exit(2));
EOF
cat >"$WORK/deny.mjs" <<EOF
const url = "http://${RELEASE}-relaycast.${NS}.svc:8787/health";
const ac = new AbortController();
setTimeout(() => ac.abort(), 8000);
fetch(url, { signal: ac.signal }).then(() => process.exit(0)).catch(() => process.exit(2));
EOF
kubectl -n "$NS" create configmap np-allow --from-file=check.mjs="$WORK/allow.mjs" --dry-run=client -o yaml \
  | kubectl -n "$NS" apply -f - >/dev/null
kubectl create namespace "$OUT_NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl -n "$OUT_NS" create configmap np-deny --from-file=check.mjs="$WORK/deny.mjs" --dry-run=client -o yaml \
  | kubectl -n "$OUT_NS" apply -f - >/dev/null
client_pod "$NS" np-allow "$WORK/allow.mjs"
client_pod "$OUT_NS" np-deny "$WORK/deny.mjs"
allow_code=$(wait_exit "$NS" np-allow)
deny_code=$(wait_exit "$OUT_NS" np-deny)
[ "$allow_code" = 0 ] && echo "PASS same-namespace client reached /health" || { echo "FAIL same-namespace client exit $allow_code"; exit 1; }
[ "$deny_code" = 2 ] && echo "PASS cross-namespace NetworkPolicy denied /health" || { echo "FAIL cross-namespace client exit $deny_code"; exit 1; }

echo "--- unauthenticated internal route"
cat >"$WORK/internal.mjs" <<EOF
const base = "http://${RELEASE}-relaycast.${NS}.svc:8787";
const ac = new AbortController();
setTimeout(() => ac.abort(), 8000);
const headers = { "content-type": "application/json" };
Promise.all([
  fetch(base + "/internal/workspaces", { method: "POST", headers, body: JSON.stringify({ name: "x" }), signal: ac.signal }),
  fetch(base + "/v1/workspaces", { method: "POST", headers, body: JSON.stringify({ name: "x" }), signal: ac.signal }),
]).then(async ([internal, pub]) => {
  if (internal.status === 201 || pub.status === 201) process.exit(1);
  if (pub.status !== 404) process.exit(1);
  process.exit(0);
}).catch(() => process.exit(2));
EOF
kubectl -n "$NS" create configmap np-internal --from-file=check.mjs="$WORK/internal.mjs" --dry-run=client -o yaml \
  | kubectl -n "$NS" apply -f - >/dev/null
client_pod "$NS" np-internal "$WORK/internal.mjs"
internal_code=$(wait_exit "$NS" np-internal)
[ "$internal_code" = 0 ] && echo "PASS unauthenticated /internal is not a create and anonymous /v1/workspaces is 404" \
  || { echo "FAIL internal-route client exit $internal_code"; exit 1; }

forward() {
  [ -n "$PF_PID" ] && kill "$PF_PID" 2>/dev/null || true
  PF_PID=
  kubectl -n "$NS" wait --for=condition=Ready pod -l "$SEL" --timeout=300s >/dev/null
  kubectl -n "$NS" port-forward "svc/${RELEASE}-relaycast" "$PORT:8787" >"$WORK/pf.log" 2>&1 &
  PF_PID=$!
  local _
  for _ in $(seq 60); do curl -sf "http://127.0.0.1:$PORT/health" >/dev/null && return 0; sleep 1; done
  cat "$WORK/pf.log" >&2
  return 1
}
status() { curl -s -o /dev/null -w '%{http_code}' "$@"; }
smoke() { B="http://127.0.0.1:$PORT" STATE="$WORK/state-$1.json" node "$ROOT/ci/relaycast/smoke.mjs" "$2"; }

forward
code=$(status -XPOST -H 'content-type: application/json' -d '{"name":"x"}' "http://127.0.0.1:$PORT/v1/workspaces")
[ "$code" = 404 ] && echo "PASS port-forward anonymous POST /v1/workspaces -> 404" || { echo "FAIL anonymous create -> $code"; exit 1; }

echo "--- authenticated bootstrap and read"
kubectl -n "$NS" exec "deploy/${RELEASE}-relaycast" -- node -e '
  const s = require("fs").readFileSync("/run/secrets/relaycast/internal-secret", "utf8").trim();
  fetch("http://127.0.0.1:8787/internal/workspaces", { method: "POST",
    headers: { authorization: "Bearer " + s, "content-type": "application/json" },
    body: JSON.stringify({ name: process.argv[1] }) })
    .then(async (r) => { process.stdout.write(await r.text() + "\n"); process.exitCode = r.status === 201 ? 0 : 1; });
' smoke-team >"$WORK/workspace.json"
node -e 'const fs=require("fs"); fs.writeFileSync(process.argv[2], JSON.parse(fs.readFileSync(process.argv[1],"utf8")).data.api_key)' \
  "$WORK/workspace.json" "$WORK/ws.key"
echo "PASS first-run bootstrap created a workspace"
B="http://127.0.0.1:$PORT" STATE="$WORK/state-new.json" WORKSPACE_KEY_FILE="$WORK/ws.key" node "$ROOT/ci/relaycast/smoke.mjs" full

echo "--- restart"
kubectl -n "$NS" rollout restart "deploy/${RELEASE}-relaycast" >/dev/null
kubectl -n "$NS" rollout status "deploy/${RELEASE}-relaycast" --timeout=300s >/dev/null
forward
smoke new restart

echo "--- backup + restore"
kubectl -n "$NS" create job --from="cronjob/${RELEASE}-relaycast-backup" smoke-backup >/dev/null
kubectl -n "$NS" wait --for=condition=complete job/smoke-backup --timeout=300s >/dev/null
BACKUP=$(kubectl -n "$NS" logs job/smoke-backup | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s.trim().split("\n").pop()).backup))')
echo "PASS backup $BACKUP"
KEY=$(cat "$WORK/ws.key")
AT=$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).at)' "$WORK/state-new.json")
code=$(status -XPOST -H "authorization: Bearer $AT" -H 'content-type: application/json' \
  -d '{"text":"after-backup-quokka"}' "http://127.0.0.1:$PORT/v1/channels/general/messages")
[ "$code" = 201 ] || { echo "FAIL post-backup message -> $code"; exit 1; }
search_has() {
  local body
  body=$(curl -sf -H "authorization: Bearer $KEY" "http://127.0.0.1:$PORT/v1/search?q=quokka") \
    || { echo "FAIL search request failed"; exit 1; }
  grep -q '"ok":true' <<<"$body" || { echo "FAIL search response not ok"; exit 1; }
  grep -q "$1" <<<"$body"
}
search_has after-backup-quokka || { echo "FAIL post-backup message is not searchable before the restore"; exit 1; }
echo "PASS post-backup message searchable before restore"
kill "$PF_PID"; PF_PID=
NS="$NS" RELEASE="$RELEASE" BACKUP="$BACKUP" "$ROOT/ci/relaycast/restore.sh" >/dev/null
forward
if search_has after-backup-quokka; then
  echo "FAIL message written after the backup survived the restore"
  exit 1
fi
echo "PASS restore rolled back to $BACKUP"
unset KEY AT
smoke new restore
echo "--- self-hosted smoke passed"
