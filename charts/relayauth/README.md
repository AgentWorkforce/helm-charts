# RelayAuth Helm chart

This hook-free chart runs the RelayAuth Node server as a single SQLite writer.
It is designed for both `helm install` and Alchemy's deterministic
`helm template --no-hooks` plus server-side apply workflow.

## Required inputs

RelayAuth credentials are deliberately external to the chart:

```bash
kubectl create namespace auth
kubectl -n auth create secret generic relayauth \
  --from-file=internal-secret=./internal-secret \
  --from-file=signing-key.pem=./signing-key.pem \
  --from-file=bootstrap-api-key=./bootstrap-api-key

helm install relayauth oci://ghcr.io/agentworkforce/charts/relayauth \
  --namespace auth \
  --set existingSecret=relayauth
```

The Secret is mounted as files; no secret value or private key is accepted in
chart values. Chart `0.1.1` defaults to the public multi-platform RelayAuth
image built from source revision
`784582ef983bb72b13b43512d9a4142ef5dfabb2` at
`sha256:c23c92d25fdffef3b5838a1eef4c226925f859706365d9ccece229795b877288`.
Image overrides must also use an immutable SHA-256 digest; mutable tags are
rejected during rendering.

## Runtime contract

- Exactly one replica with `Recreate`, backed by a `ReadWriteOnce` PVC.
- HTTP port `8787`; startup, readiness, and liveness probes use `/health`.
- Non-root UID/GID 1000, no service-account token, no privilege escalation,
  all Linux capabilities dropped, and a read-only root filesystem. `/data`
  and `/tmp` are the only writable mounts.
- `baseUrl` controls discovery and the advertised JWKS URL. It defaults to the
  release's in-cluster Service URL. `issuer` defaults to `baseUrl`.
- `jwksIngress` optionally exposes only `/.well-known/*`; it does not expose
  token or administration APIs.
- When `jwksIngress` and `networkPolicy` are both enabled,
  `networkPolicy.ingressFrom` must explicitly select the ingress controller.
  The chart refuses an ingress whose backend would be blocked by its own
  default policy.
- `cors.allowedOrigins` configures CORS. It is not a token audience allowlist.
  A RelayHistory assertion's sole audience is the canonical `historyOrigin`
  supplied by its authorized minting client. The current RelayAuth runtime has
  no static audience-registration environment variable; hosted audience
  ownership therefore lives outside this chart.

For in-cluster History over private HTTP, set
`relayhistory.allowPrivateHttpOrigin=true`. Public origins still require HTTPS.

## RelayAuth-issued relaycast credentials (model B)

RelayAuth can own the `ar_` credential tag keyring and push `ar_ws_` workspace
keys into a Relaycast deployment, which then verifies tags through RelayAuth's
remote CredentialTagger. Set both `secretKeys.relaycastCredentialKeyring` (the
`ar_` keyring) and `secretKeys.relaycastInternalSecret` (Relaycast's internal
admin secret) — the chart refuses partial wiring — and point `relaycast.url`
at the Relaycast Service (default `http://relaycast:8787`).
`secretKeys.relaycastServiceApiKey` adds an optional service API key. The
relaycast chart side is `credentials.authority=relayauth`.

## Rotation

Set `secretKeys.signingKeyNext` to pre-publish the next public key, promote it
to `secretKeys.signingKey`, and retain the old public key under
`secretKeys.signingKeyPrevious` until old tokens and verifier caches expire.
RelayAuth reads key files at boot, so restart the Deployment after every Secret
change. The PVC is annotated `helm.sh/resource-policy: keep` by default.
