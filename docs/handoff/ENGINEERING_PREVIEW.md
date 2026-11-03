# Engineering preview — not customer-installable

This archive is the complete current Helm-chart and agent-prompt engineering
handoff. It is provided for architecture and integration review, not
installation or production use.

Hard blockers as of 2026-11-02:

- RelayHistory's proof image is based on a stale branch and lacks 17
  current-main migrations.
- RelayHistory, the Sessions Pipeline, the control API, and Dashboard do not yet
  have approved customer image channels from reproducible committed sources.
- The control API proof image is amd64-only.
- A durable runtime bridge from the Sessions Pipeline to RelayHistory is not
  implemented; only the protocol contract and fixtures are validated.
- Repository branch protection/provenance gates are not fully available or
  configured.

Do not run the installation prompts until all of the following hold:

1. `python3 scripts/release/validate-customer-release.py --require-clean`
   passes for the exact source revision of this archive. It checks the image
   manifest (`self-hosted/customer-images.yaml`), branch-protection and
   provenance controls, and RelayHistory migration evidence.
2. Every hard blocker listed above is explicitly closed, with evidence,
   including those the validator does not check. In particular, the validator
   does not check the Sessions Pipeline to RelayHistory runtime bridge; that
   blocker stays open until the bridge is implemented and verified end to end.
3. Every image is replaced with an approved, customer-accessible immutable
   digest.

A clean `self-hosted/customer-images.yaml` alone is not sufficient: its
blockers cover images only.
