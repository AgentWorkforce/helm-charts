# Agent Relay self-hosted GCP proof

Customer handoff for the requested **Helm charts + agent prompts**.

## Download

- [Complete handoff bundle](https://github.com/AgentWorkforce/helm-charts/releases/download/selfhost-gcp-proof-0.1.0/agent-relay-selfhost-gcp-handoff-0.1.0.tar.gz)
- [Standalone agent prompts](https://github.com/AgentWorkforce/helm-charts/releases/download/selfhost-gcp-proof-0.1.0/AGENT_PROMPTS.md)
- [Architecture](https://github.com/AgentWorkforce/helm-charts/releases/download/selfhost-gcp-proof-0.1.0/ARCHITECTURE.md)
- [Bundle checksum](https://github.com/AgentWorkforce/helm-charts/releases/download/selfhost-gcp-proof-0.1.0/BUNDLE_SHA256SUM)

The bundle contains:

- self-contained `agent-relay-0.1.0.tgz` umbrella Helm chart;
- reusable setup skill plus copy/paste planning, installation, Desktop,
  end-to-end proof, and recovery prompts;
- human quick-start and architecture guide;
- structural GCP values example and checksums.

The chart covers Relaycast, RelayAuth, 96Bulls Sessions, RelayHistory, the
headless control-plane API, Relay Dashboard, and custom-origin Desktop setup.
Relayflows, Relayfile, billing, provider integrations, and hosted fleet are out
of scope.

This is a `portable-single` prerelease proof, not an HA or production-readiness
claim. Proof images currently live in a private registry, and the RelayHistory
image is experimental. Publish approved digest-pinned images to the customer's
authorized registry before customer installation.

The GCP proof workloads and load-balancer backends are healthy. Public demo DNS
and TLS remain pending parent-zone delegation.
