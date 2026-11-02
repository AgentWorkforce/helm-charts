# Engineering preview — not customer-installable

This archive is the complete current Helm-chart and agent-prompt engineering
handoff. It is provided for architecture and integration review, not
installation or production use.

Hard blockers as of 2026-11-02:

- RelayHistory's proof image is based on a stale branch and lacks 17
  current-main migrations.
- RelayHistory, 96Bulls Sessions, the control API, and Dashboard do not yet
  have approved customer image channels from reproducible committed sources.
- The control API proof image is amd64-only.
- A durable runtime bridge from 96Bulls Sessions to RelayHistory is not
  implemented; only the protocol contract and fixtures are validated.
- Repository branch protection/provenance gates are not fully available or
  configured.

Do not run the installation prompts until `self-hosted/customer-images.yaml`
reports no hard blockers and every image is replaced with an approved,
customer-accessible immutable digest.
