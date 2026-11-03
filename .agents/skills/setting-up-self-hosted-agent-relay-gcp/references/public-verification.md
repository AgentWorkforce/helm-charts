# Public endpoint verification

`verify-public.sh` derives all origins from `BASE_DOMAIN`. To use explicit
origins, set all of `DASHBOARD_URL`, `CONTROL_PLANE_URL` (or `API_URL`),
`RELAYCAST_URL`, and `RELAYHISTORY_URL`. Each must be a credential-free HTTPS
origin with no path, query, or fragment.

Optional non-secret controls are:

- `DASHBOARD_HEALTH_PATH` (default `/healthz`)
- `CONTROL_PLANE_HEALTH_PATH` (default `/healthz`)
- `RELAYCAST_HEALTH_PATH` (default `/health`)
- `RELAYHISTORY_HEALTH_PATH` (default `/healthz`)
- `VERIFY_DNS_RESOLVER` (requires `dig` when set)
- `VERIFY_DNS_TIMEOUT`, `VERIFY_CONNECT_TIMEOUT`, `VERIFY_TLS_TIMEOUT`, and
  `VERIFY_MAX_TIME`, in seconds
- `VERIFY_CA_BUNDLE`, for an operator-approved CA file

The verifier checks public A/AAAA results, rejects non-global addresses,
validates each certificate chain and hostname with SNI, and requires a 2xx
health response without following redirects. It sends no credentials and
prints no response bodies or headers. Do not continue on a certificate
mismatch, redirect, plaintext endpoint, non-public address, or failed health
check.
