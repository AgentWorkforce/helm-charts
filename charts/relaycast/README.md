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
  --set baseUrl=https://relay.example.com
```

`baseUrl` must be the HTTPS origin clients will eventually use because Relaycast
embeds it in signed file URLs and A2A cards.

The pinned runtime cannot authenticate anonymous `POST /v1/workspaces`, so the
chart keeps the Service on `ClusterIP` and rejects `ingress.enabled=true`.
Bootstrap and use this portable profile from inside the cluster or through an
operator port-forward. Do not put an Ingress, Gateway, NodePort, or load balancer
directly in front of the application Service; doing so would let arbitrary
internet clients allocate workspaces on the sole SQLite volume. A later digest
may expose the service only after the runtime has a proven authentication
mechanism.

The pinned, published 8.0.0 image predates Relaycast's workspace-bootstrap
Secret support. This chart therefore rejects those later environment variables
instead of silently accepting an ineffective Secret. Add the structured Secret
configuration only when a supporting image is published and digest-pinned.

The image and PVC are retained independently: the image is pinned to an
immutable multi-platform digest, and the generated PVC carries
`helm.sh/resource-policy: keep` by default.

## Composition

Install add-ons separately and point them at the core through their documented
URLs and credentials. Relayflows is needed only for durable workflow execution;
96Bulls is needed only for session capture/evaluation. Neither is part of the
Relaycast availability path.
