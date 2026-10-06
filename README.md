# AgentWorkforce Helm Charts

Single Helm chart repository for all AgentWorkforce services. Each service lives under `charts/<service-name>/`.

## Charts

| Chart | Description |
|-------|-------------|
| [relayfile](charts/relayfile) | Relayfile server — single Go binary, HTTP on :8080, Postgres-backed in production |
| [relayflows](charts/relayflows) | Relayflows customer-cloud worker — runs workflow assignments inside a customer's Kubernetes cluster |

## Quick start

```bash
helm repo add agentworkforce https://AgentWorkforce.github.io/helm-charts
helm repo update
```

### Install relayfile

```bash
helm install relayfile agentworkforce/relayfile \
  --set secrets.internalHmacSecret=<strong-secret> \
  --set secrets.productionDsn='postgres://user:pass@host:5432/dbname?sslmode=require' \
  --set auth.jwksUrl=https://auth.relay.example.com/.well-known/jwks.json
```

See [charts/relayfile/README.md](charts/relayfile/README.md) for the full parameter reference.

### Install Relayflows worker

Create a Secret from a fresh worker enrollment token, then install the
single-replica outbound worker:

```bash
set -euo pipefail
kubectl create namespace relayflows --dry-run=client -o yaml | kubectl apply -f -
umask 077
token_file=$(mktemp)
trap 'rm -f "$token_file"' EXIT
if ! read -rsp 'Enrollment token: ' enrollment_token; then
  printf '\nUnable to read enrollment token.\n' >&2
  exit 1
fi
printf '\n'
if [ -z "$enrollment_token" ]; then
  echo 'Enrollment token must not be empty.' >&2
  exit 1
fi
printf '%s' "$enrollment_token" >"$token_file"
unset enrollment_token
kubectl -n relayflows create secret generic relayflows-enrollment \
  --from-file=AGENT_RELAY_WORKER_ENROLLMENT_TOKEN="$token_file" \
  --dry-run=client -o yaml | kubectl apply -f -
rm -f "$token_file"
trap - EXIT
helm install relayflows agentworkforce/relayflows \
  --namespace relayflows \
  --set credentials.existingSecret=relayflows-enrollment
```

See [charts/relayflows/README.md](charts/relayflows/README.md) for the runtime
image contract, persistence requirements, and production configuration.

## Releases

Charts are packaged and published to GitHub Pages via [helm/chart-releaser-action](https://github.com/helm/chart-releaser-action) on every merge to `main`. chart-releaser detects changed chart versions automatically — each service chart is released independently.

## Contributing

Add new service charts under `charts/<service-name>/`. Open a PR against `main`. Merges are gated by Khaliq.
