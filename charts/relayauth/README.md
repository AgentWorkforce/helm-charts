# RelayAuth Helm chart

This hook-free chart runs the RelayAuth Node server as a single SQLite writer.
It is designed for both `helm install` and Alchemy's deterministic
`helm template --no-hooks` plus server-side apply workflow.

## Required inputs

RelayAuth images and credentials are deliberately external to the chart:

```bash
kubectl -n auth create secret generic relayauth \
  --from-file=internal-secret=./internal-secret \
  --from-file=signing-key.pem=./signing-key.pem \
  --from-file=bootstrap-api-key=./bootstrap-api-key

helm install relayauth oci://ghcr.io/agentworkforce/charts/relayauth \
  --namespace auth --create-namespace \
  --set existingSecret=relayauth \
  --set image.digest=sha256:<released-image-digest>
```

The Secret is mounted as files; no secret value or private key is accepted in
chart values. The image must be selected by an immutable SHA-256 digest.

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
- `cors.allowedOrigins` configures CORS. It is not a token audience allowlist.
  A RelayHistory assertion's sole audience is the canonical `historyOrigin`
  supplied by its authorized minting client. The current RelayAuth runtime has
  no static audience-registration environment variable; hosted audience
  ownership therefore lives outside this chart.

For in-cluster History over private HTTP, set
`relayhistory.allowPrivateHttpOrigin=true`. Public origins still require HTTPS.

## Rotation

Set `secretKeys.signingKeyNext` to pre-publish the next public key, promote it
to `secretKeys.signingKey`, and retain the old public key under
`secretKeys.signingKeyPrevious` until old tokens and verifier caches expire.
RelayAuth reads key files at boot, so restart the Deployment after every Secret
change. The PVC is annotated `helm.sh/resource-policy: keep` by default.
