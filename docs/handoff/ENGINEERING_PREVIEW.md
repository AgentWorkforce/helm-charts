# Engineering preview — not customer-installable

This archive is the complete current Helm-chart and agent-prompt engineering
handoff. It is provided for architecture and integration review, not
installation or production use.

Hard blockers as of 2026-11-03 (agent-relay 0.3.6; details in [STATUS.md](STATUS.md)):

- The RelayHistory and Sessions services release images are not published
  yet, so those two images stay REQUIRED OVERRIDE in `values-gcp.yaml`.
- The control-plane API image is published but its GHCR package is not public
  yet.
- Session ingest auth: Desktop couriers need machine-bound History
  assertions. The interim RelayAuth bearer is off in the customer profile, and
  ingest without it has not been verified end to end.
- Branch protection and a protected release environment are not configured.
- The supported-100 load and soak test, alerts, dashboards and runbooks
  evidence, and the server/Desktop version-compatibility matrix have not run.
- The custom-origin Desktop is green in CI but not merged or released.
- The Sessions Pipeline to RelayHistory durable runtime bridge was recorded as
  not implemented on 2026-11-02. This release does not re-verify it.

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
