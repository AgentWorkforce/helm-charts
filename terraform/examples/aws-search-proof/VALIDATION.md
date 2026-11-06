# Source validation receipt

Base: `d3040fa209ef5c90ce61bde2a776f783c01cfaba` (fresh origin/main, including PR64).
Only this new example and the explicitly reviewed `modules/aws/search` lifecycle
seam change. Exact tested head/source hashes are recorded in the held PR and
external receipt, avoiding a self-referential commit value here.

No cloud calls, credentials, live plans/applies, protected SQL, IAM deployment,
profile activation, image publication, merge or runtime provider proof occurred.
This Terraform/Python-only worktree has no npm manifest and required no npm
install, invented lockfile or dependency symlink.

- Terraform 1.16.7 and OpenTofu 1.11.14: backend-disabled init/validate; seven
  portable module cases and twelve root cases pass under each engine. Disposable
  native mock apply/teardown succeeds; protected defaults remain literal guarded.
- Terraform-only historical state test shares mock state from the unindexed
  module at the base commit, applies the new default module and asserts the same
  randomly generated resource ID; protected-to-disposable planning is refused.
  The expected protected mock teardown also refuses destruction. This uses
  `state_key`, unsupported by OpenTofu 1.11, and is not a real customer migration.
- Full source parity check compares every domain argument/security block across
  protected/disposable branches, excluding only count and the literal guard.
- Existing AWS example (two cases) and aws-environments (27 cases) pass in an
  isolated T7 source copy using the changed shared module. No consumer source is
  edited; the separate Lambda environment-binding follow-up remains open.
- Eighteen Python offline tests cover all original context hashes, stale/foreign
  context, fresh caller versus cached plan identity, original approval versus
  current teardown hashes, exact create/delete payload/address fences, public
  policy/role/metadata/capacity refusal, SG peers, incomplete ENI pages, typed
  NotFound/credential error distinctions, no capability-to-common permission
  fallback, inherited refresh metadata and unrelated evidence preservation.
  An inert local Python parent/grandchild timeout preserves partial output and
  proves its owned process group absent; it invokes no AWS or credential tool.
- TFLint 0.64.0, Terraform formatting, Python AST, Git whitespace and repository
  terraform-docs 0.24.0 output checks pass for the module/root.
- Checkov 3.3.30 whole Terraform tree: 446 passed, zero failed, 110 documented
  skips. New proof root/local module: 18 passed, zero failed, nine skips. Its
  explicit master/HA and content-log exceptions are bounded disposable choices;
  existing protected defaults/security inputs are not weakened.

AWS provider is pinned to 6.72.0 in the committed Terraform lock. OpenTofu checks
use an isolated source copy and its separately verified registry package lock
for the same version; those distribution/checksum changes never modify the
committed lock. Provider binaries are not claimed byte-identical across registries.

Native DNS/routes/NACL/private connectivity, service-linked role and external
identity availability, capability deployment/human provenance/expiry, managed
domain behavior, FGAC/data runtime, exact service ENIs and asynchronous retirement
remain future independent operator evidence. The source runner has not executed
an operational plan. Pending/partial applies require exact-owned recovery, not
an empty-state inference or state/protection bypass.
