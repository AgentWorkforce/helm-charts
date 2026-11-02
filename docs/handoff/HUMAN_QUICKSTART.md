# Human quick start: self-hosted Agent Relay on GCP

This proof installs Relaycast, RelayAuth, 96Bulls Sessions, RelayHistory, the
headless control-plane API, and Relay Dashboard. It intentionally excludes
Flows, Relayfile, billing, hosted fleet, and provider integrations.

The deployment is `portable-single`, not highly available.

## 1. Prerequisites

- GKE 1.28+ with Workload Identity
- PostgreSQL 17 with `vector` and `pg_trgm`
- separate runtime and migration-owner database roles
- a dedicated RelayHistory database (never reuse the 96Bulls `hoopdb`)
- GCS, Artifact Registry, a global static address, and authoritative DNS
- `gcloud`, `kubectl`, `helm`, `kubeconform`, `jq`, `yq`, Node, and OpenSSL
- approved immutable images in a registry the customer GKE nodes can pull

The proof’s API, Dashboard, and RelayHistory images are not a public customer
distribution channel. Promote approved builds into the customer registry and
replace every repository and digest in the values overlay.

## 2. Unpack

```bash
tar -xzf agent-relay-selfhost-gcp-handoff-0.1.0.tar.gz
tar -xzf agent-relay-0.1.0.tgz
cp agent-relay/values-gcp.yaml customer-values.yaml
```

Install the skill by copying
`setting-up-self-hosted-agent-relay-gcp/` into the agent’s skills directory,
or give its `SKILL.md` to the deployment agent as the operating procedure.

## 3. Customize

Edit `customer-values.yaml` and replace every proof-specific:

- project, region, bucket, registry, and organization ID;
- Dashboard, API, Relaycast, and RelayHistory hostname;
- static IP, ManagedCertificate, and FrontendConfig name;
- Kubernetes Secret and service-account reference;
- image repository and immutable `sha256:` digest;
- PostgreSQL runtime role.

Keep credentials out of the values file. Create the documented Kubernetes
Secret from an approved secret manager or private mode-0600 files. RelayHistory
and the control API each need separate runtime and migration database URLs.

## 4. Validate

```bash
helm lint --strict ./agent-relay -f customer-values.yaml
helm template agent-relay ./agent-relay \
  --namespace agent-relay --no-hooks \
  -f customer-values.yaml |
  kubeconform -strict -summary -ignore-missing-schemas
```

Confirm the render contains no Secret objects, mutable image tags, public
LoadBalancer Services, Helm hooks, or proof-specific names.

## 5. Install

```bash
helm install agent-relay ./agent-relay \
  --namespace agent-relay --create-namespace --no-hooks \
  -f customer-values.yaml \
  --wait --wait-for-jobs --timeout 20m
```

Do not add `--atomic`: Helm rollback does not reverse completed database
migrations. Upgrades require the bundled pre-upgrade evidence gate and a tested
isolated restore.

Wait for both migration Jobs, all Deployments, GKE backends, public DNS, and
the managed certificate.

## 6. Connect Desktop

In Agent Relay Desktop Settings, set the trusted deployment origin to the
public API origin, for example `https://api.relay.customer.example`. The
current implementation accepts only a bare public HTTPS DNS origin. Complete
device approval; the control plane supplies scoped Relaycast and RelayHistory
credentials.

## 7. Verify

Run the bundled skill’s `scripts/verify-public.sh`, then:

1. register two agents and require a ping plus reply;
2. upload a marked session through `/v1/delivery/batches`;
3. retry the identical batch and require the same durable receipt;
4. verify Dashboard list, search, and replay;
5. verify cross-workspace denial and restart persistence;
6. run an idempotent Helm upgrade and test restore into an isolated database.

Do not claim customer readiness until all checks pass with the customer’s
domains, registry, identities, and backup policy.
