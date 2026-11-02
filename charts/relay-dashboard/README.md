# relay-dashboard

Deploys the self-hosted Agent Relay dashboard container. The image digest is
required; this chart never follows a tag and does not create Secrets. Runtime
settings are passed with `DASHBOARD_PUBLIC_URL`, `DASHBOARD_APP_PATH`,
`DASHBOARD_API_BASE_PATH`, and `DASHBOARD_LOGIN_PATH`.

The browser calls `runtime.apiBasePath` (default `/cloud/api`) on its current
origin. When ingress is enabled, the chart routes `runtime.apiBasePath` and
`runtime.loginPath` to `api.serviceName` and `/` to the dashboard.
The API Service must exist in the same namespace. The separate
`relay-cloud-api` ingress can expose that same Service on an `api.` host.

The current dashboard image is a single static replica. This chart makes no HA
claim. Publish and verify the dashboard image before replacing the digest in a
deployment values file.

```sh
helm lint --strict charts/relay-dashboard \
  -f charts/relay-dashboard/ci/default-values.yaml
```
