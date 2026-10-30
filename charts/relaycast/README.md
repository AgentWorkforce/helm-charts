# Relaycast Helm chart

This chart runs the portable Relaycast core on Kubernetes. It deliberately has
no dependency on Relayflows, RelayAuth, Relayfile, 96Bulls, or a cloud provider.

The current self-host runtime is a single Node process backed by SQLite and a
local uploaded-file store. Both live on one persistent volume, so the chart
enforces one replica and `Recreate` upgrades. This is the first portable
self-host profile; horizontally scalable cloud adapters will retain the same
Relaycast API but require a separately proven runtime. `runtime.backend` is
therefore fixed to `sqlite`; the chart refuses names for unimplemented backends.

## Install

```bash
kubectl create namespace relaycast
helm install relaycast agentworkforce/relaycast -n relaycast \
  --set baseUrl=https://relay.example.com \
  --set ingress.enabled=true \
  --set ingress.hosts[0]=relay.example.com \
  --set ingress.tls[0].secretName=relay-example-com-tls \
  --set ingress.tls[0].hosts[0]=relay.example.com
```

TLS must terminate before traffic reaches the pod, and the ingress or load
balancer must preserve WebSocket upgrades. `baseUrl` must be the public HTTPS
origin clients actually use because Relaycast embeds it in signed file URLs and
A2A cards.

The pinned, published 8.0.0 image predates Relaycast's workspace-bootstrap
Secret support. This chart therefore rejects those later environment variables
instead of silently accepting an ineffective Secret. Add the structured Secret
configuration only when a supporting image is published and digest-pinned.

Ingress-controller limits still apply to WebSocket lifetime and upload size.
For ingress-nginx, configure suitable `proxy-read-timeout` and
`proxy-body-size` annotations for your operating requirements.

The image and PVC are retained independently: the image is pinned to an
immutable multi-platform digest, and the generated PVC carries
`helm.sh/resource-policy: keep` by default.

## Composition

Install add-ons separately and point them at the core through their documented
URLs and credentials. Relayflows is needed only for durable workflow execution;
96Bulls is needed only for session capture/evaluation. Neither is part of the
Relaycast availability path.
