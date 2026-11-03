# Agent Relay self-hosted GCP handoff

Customer handoff for the requested **Helm charts + agent prompts**.

## Artifacts

`scripts/package-customer-handoff.sh build --output-dir <dir>` produces, for
one source revision:

- `agent-relay-customer-handoff-<rev12>.tar.gz`
- `agent-relay-customer-handoff-<rev12>.zip` (identical content)
- `SHA256SUMS` covering both archives

No release workflow publishes these files. The release owner uploads all three,
unchanged, to the agreed delivery channel and gives the customer the full
source revision so they can match it against `RELEASE-MANIFEST.json`. A
`-DEVELOPMENT-PREVIEW` or `-INCOMPLETE` archive must never be delivered as a
customer release.

Each archive unpacks to `agent-relay-customer-handoff/` and contains:

- the `agent-relay` umbrella chart and its leaf charts as source (run
  `helm dependency build` at install time), with the structural
  `values-gcp.yaml` example;
- the reusable `setting-up-self-hosted-agent-relay-gcp` setup skill;
- the reference architecture, image supply chain, backup/restore runbook,
  conformance contract, and license docs;
- read-only verification, pre-upgrade, release-validation, and conformance
  scripts;
- `RELEASE-MANIFEST.json` and an inner `SHA256SUMS`.

See [`HANDOFF.md`](HANDOFF.md) for the full layout and verification steps.

The charts cover Relaycast, RelayAuth, 96Bulls Sessions, RelayHistory, the
headless control-plane API, Relay Dashboard, and custom-origin Desktop setup.
Relayflows, Relayfile, billing, provider integrations, and hosted fleet are out
of scope.

This is a `portable-single` prerelease, not an HA or production-readiness
claim. The internal proof images live in a private registry, and the
RelayHistory image is experimental. Publish approved digest-pinned images to
the customer's authorized registry before customer installation.
