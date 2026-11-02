# Agent Relay self-hosted GCP handoff

## Deliverables

- `agent-relay-0.1.0.tgz`: self-contained umbrella Helm chart with Relaycast,
  RelayAuth, 96Bulls Sessions, RelayHistory, the headless control-plane API,
  and Relay Dashboard.
- `setting-up-self-hosted-agent-relay-gcp-skill.tar.gz`: setup, safety,
  preflight, deployment, Desktop, and public-verification guidance.
- `AGENT_PROMPTS.md`: copy/paste prompts for planning, installation, Desktop
  bootstrap, end-to-end proof, and recovery.
- `HUMAN_QUICKSTART.md`: operator quick-start.
- `ARCHITECTURE.md`: deployment architecture and trust boundaries.
- `selfhost-backup-restore.md`: backup, isolated restore, rollback, and
  recovery verification for Cloud SQL, GCS, Relaycast, and RelayAuth.
- `SHA256SUMS`: checksums for the chart, skill, prompts, and guides.

## Proof environment

- Project: `agentrelay-96bulls-soc2-2610` (`955297012355`)
- Region/cluster: `us-central1` / `awf-conformance-gke`
- Namespace/release: `agent-relay` / `agent-relay`, Helm revision 4
- Ingress address: `34.111.70.61`
- Dashboard: `https://gcp-proof.agentrelay.com`
- API: `https://api.gcp-proof.agentrelay.com`
- Relaycast: `https://cast.gcp-proof.agentrelay.com`
- RelayHistory: `https://history.gcp-proof.agentrelay.com`

The workloads and load-balancer backends are healthy. Public DNS and TLS remain
pending until the parent `agentrelay.com` zone delegates `gcp-proof` to the
four Google Cloud DNS nameservers printed by the setup process.

## Verified behavior

- all four workloads and both migration Jobs ready;
- idempotent Helm upgrade completed;
- two Relaycast agents exchanged a ping and reply;
- a 24-record native delivery batch received a durable receipt;
- an identical retry returned the same receipt;
- Dashboard API search returned three sessions and replay returned four events;
- all sessions and events remained readable after a RelayHistory restart.

## Customer use

Treat `values-gcp-proof.yaml` as a structural example, not customer
configuration. Follow the bundled skill to create a non-secret customer
overlay and replace every proof-specific domain, project, bucket, registry,
Secret reference, database role, and image digest.

This is a `portable-single` proof, not an HA claim. The RelayHistory image is
an experimental proof build and the proof images in the private Artifact
Registry are not a customer distribution channel. Publish approved images to
the customer's authorized registry before installation.
