# relay-dashboard

Deploys the self-hosted Agent Relay dashboard container. The image digest is
required; this chart never follows a tag and does not create Secrets. Runtime
settings are passed with `DASHBOARD_PUBLIC_URL`, `DASHBOARD_APP_PATH`,
`DASHBOARD_API_BASE_PATH`, and `DASHBOARD_LOGIN_PATH`.

The browser calls `runtime.apiBasePath` (default `/cloud/api`) on its current
origin. When ingress is enabled, the chart routes `runtime.apiBasePath` and
`runtime.loginPath` to `api.serviceName` and `/` to the dashboard.
`api.serviceName` has no default and is required with ingress: set it to the
relay-cloud-api Service in the same namespace, which is that release's
fullname (`<release>-relay-cloud-api`, or its `fullnameOverride`; for example
`api-relay-cloud-api` after `helm install api charts/relay-cloud-api`). The separate
`relay-cloud-api` ingress can expose that same Service on an `api.` host.

Single-host mode: with `global.singleHost.host` set (normally once on the
agent-relay umbrella), `runtime.publicUrl` and `ingress.host` are derived as
`https://<host>` and `<host>` (leave them empty), and the Ingress also routes
`/api` to the API, because flows workers and the integrations OAuth callback
call `<publicUrl>/api/v1/...` there. Keep the `relay-cloud-api` ingress
disabled in that mode. See the agent-relay README, "Single-host mode".

The current dashboard image is a single static replica. This chart makes no HA
claim. Publish and verify the dashboard image before replacing the digest in a
deployment values file.

```sh
helm lint --strict charts/relay-dashboard \
  -f charts/relay-dashboard/ci/default-values.yaml
```
