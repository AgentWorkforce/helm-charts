# Relaycast Helm chart

This chart runs the portable Relaycast core on Kubernetes. It has no dependency
on Relayflows, RelayAuth, Relayfile, 96Bulls, or a cloud provider.

The self-host runtime is a single Node process backed by SQLite and a local
uploaded-file store, both on one persistent volume. The chart therefore allows
exactly one replica and upgrades with `Recreate`. `runtime.backend` is fixed to
`sqlite`, and the chart refuses names of backends that are not implemented.

## Defaults

- **Image:** pinned by immutable multi-arch digest (`linux/amd64`, `linux/arm64`).
- **Secrets:** both come from your `existingSecret` and are mounted read-only as
  files (`*_FILE`). The chart never renders a secret value.
- **Anonymous `POST /v1/workspaces`:** off (`404`). You create workspaces
  through the in-cluster admin API, as shown in [First run](#first-run).
- **Exposure:** a `ClusterIP` Service, plus a NetworkPolicy that admits only pods
  in the release namespace.
- **Persistence:** the data PVC carries `helm.sh/resource-policy: keep`.

## Quickstart

```bash
kubectl create namespace relaycast

# Two secrets, generated in place: internal admin bearer (>= 32 chars) and the
# workspace-bootstrap derivation secret. Keep both stable across upgrades.
kubectl -n relaycast create secret generic relaycast-secrets \
  --from-literal=internal-secret="$(openssl rand -hex 32)" \
  --from-literal=workspace-bootstrap-secret="$(openssl rand -hex 32)"

helm repo add agentworkforce https://agentworkforce.github.io/helm-charts
helm install relaycast agentworkforce/relaycast -n relaycast \
  --set baseUrl=https://relay.example.com \
  --set existingSecret=relaycast-secrets
```

Relaycast embeds `baseUrl` in signed file URLs and A2A cards, so set it to the
origin clients will use. For a cluster-internal deployment with no public
origin, use the Service name over http:

```bash
  --set baseUrl=http://relaycast.relaycast.svc:8787 --set allowInsecureBaseUrl=true
```

### First run

Create the first workspace through the admin API from inside the pod. The
internal secret never leaves the cluster. The response holds the only copy of
the workspace key (`rk_live_…`), so move it into your secret manager and then
delete `workspace.json`:

```bash
umask 077
kubectl -n relaycast exec deploy/relaycast -- node -e '
  const s = require("fs").readFileSync("/run/secrets/relaycast/internal-secret", "utf8").trim();
  fetch("http://127.0.0.1:8787/internal/workspaces", { method: "POST",
    headers: { authorization: "Bearer " + s, "content-type": "application/json" },
    body: JSON.stringify({ name: process.argv[1] }) })
    .then(async (r) => { process.stdout.write(await r.text() + "\n"); process.exitCode = r.status === 201 ? 0 : 1; });
' my-team > workspace.json
```

The command is safe to rerun only if you mean it: each call creates another
workspace with its own key.

### Connecting agents

The real-time receive path is the node transport. Agents use it by default
through `@relaycast/sdk`. The raw protocol is:

1. Register the agent: `POST /v1/agents` with the workspace key.
2. Mint the agent's node token: `POST /v1/agent/node-token`.
3. Connect to `/v1/node/ws?token=nt_live_…` and send a `node.register` frame.
4. Messages arrive as `deliver` frames. Acknowledge them with `delivery.ack`.

The frame shapes are in Relaycast's
[self-hosting guide](https://github.com/AgentWorkforce/relaycast/blob/main/docs/self-hosting.md#5-connecting-clients).
`GET /v1/ws` is only for observer tokens. It refuses agent tokens and
workspace keys.

## Public ingress

```yaml
ingress:
  enabled: true
  className: nginx
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt   # cert-manager issues and renews the TLS Secret
  hosts: [relay.example.com]
  tls:
    - secretName: relay-example-com-tls
      hosts: [relay.example.com]
networkPolicy:
  ingressFrom:   # required with ingress: admit the controller
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: ingress-nginx
```

Rendering is refused unless all of the following hold:

- `publicWorkspaceCreate=false`
- `baseUrl` is HTTPS
- `baseUrl`'s host is in `ingress.hosts`
- `networkPolicy.ingressFrom` is set (when the NetworkPolicy is on)

The Ingress sends every path to Relaycast except two:

- `/internal` (Prefix): the admin API.
- `/v1/workspaces` and `/v1/workspaces/` (Exact): anonymous workspace creation.

Those two go to `<release>-relaycast-deny`, a Service with no endpoints. The
controller answers `503`, so the request never reaches the engine. This works
on any controller that follows the Ingress path-precedence rules. Setting
`networkPolicy.ingressFrom` replaces the same-namespace default, so if
in-namespace clients also need access, list them too.

## Backups and restore

```yaml
backup:
  enabled: true
  schedule: "17 3 * * *"
  keep: 7
```

The backup CronJob runs the Relaycast image on the Relaycast pod's node, which
`ReadWriteOnce` requires. It takes an online snapshot through SQLite's backup
API while the engine keeps running, then checks the copy with
`PRAGMA integrity_check`. It copies `relaycast-files/` next to the snapshot and
writes everything to `relaycast-<UTC timestamp>/` on the backup PVC, marking the
directory `COMPLETE` last. Only the newest `keep` complete backups are kept. The
backup PVC is also mounted read-only in the Relaycast pod, so it binds at
install time. Copy that PVC off-cluster with your usual volume-snapshot or
object-storage tooling.

Run a backup now:

```bash
kubectl -n relaycast create job --from=cronjob/relaycast-backup relaycast-backup-manual
kubectl -n relaycast logs job/relaycast-backup-manual   # {"backup":"relaycast-20261031T000952Z",...}
kubectl -n relaycast exec deploy/relaycast -- ls /backup
```

To restore, run [`ci/relaycast/restore.sh`](../../ci/relaycast/restore.sh). It is
the exact procedure CI runs on kind:

```bash
NS=relaycast RELEASE=relaycast BACKUP=relaycast-20261031T000952Z ci/relaycast/restore.sh
```

The script does the following:

1. Scales the Deployment to 0 and waits for the pod to exit.
2. Runs a one-off Job with the same image that moves the current
   `relaycast.db*` and `relaycast-files/` aside to `/data/pre-restore-<ts>/`.
   It never deletes them.
3. Copies the backup into place.
4. Scales the Deployment back to 1.

Do not run `helm upgrade` while a restore is in progress, because it scales the
Deployment back to 1.

## Upgrades and rollback

`0.1.0` pinned Relaycast `8.0.0`, which allows anonymous workspace creation with
no way to turn it off. Treat any `0.1.0` install as private test only. Upgrade
to `0.2.0` as follows:

```bash
kubectl -n relaycast create secret generic relaycast-secrets \
  --from-literal=internal-secret="$(openssl rand -hex 32)" \
  --from-literal=workspace-bootstrap-secret="$(openssl rand -hex 32)"
helm upgrade relaycast agentworkforce/relaycast -n relaycast --version 0.2.0 \
  --set baseUrl=https://relay.example.com --set existingSecret=relaycast-secrets
```

The data PVC (`<release>-relaycast-data`) is reused. Existing workspaces, keys,
agents and history carry over, and the new engine migrates the schema on boot.

**`helm rollback` to `0.1.0` is not supported once `0.2.0` has started.** The
`8.0.0` engine cannot read the migrated schema (`no such column: "plan"`), so
every authenticated request returns `500` while `/health` still returns `200`.
To go back, restore a backup taken before the upgrade into a `0.1.0` release.
Rolling forward to `0.2.0` again restores service with the data intact.

Releases within the 12.x line apply forward-only migrations. Take a backup
before every upgrade.

## Composition

Install add-ons separately and point them at the core through their documented
URLs and credentials. Relayflows is needed only for durable workflow execution,
and 96Bulls only for session capture and evaluation. Neither is on Relaycast's
availability path.
