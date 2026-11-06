# Source/offline receipt

No cloud API, credential lookup, real plan/apply, SQL execution, deployment,
bootstrap, IAM rollout, image publication or cleanup was performed by this lane.
This is a held module-proof composition. Actual PG17/S3/restore proof remains
pending independently reviewed operator execution. Existing auxiliary fixture
results and Bulls' separate RDS bootstrap are not validation of this root.

Source base: `4df7bfd54d25aa520bcfe47c3544a87d77f7d3ac` (fresh origin/main).
Only this example path is changed. Exact tested commit and clean artifact hashes
are recorded in the held PR/evidence, avoiding a self-referential source receipt.

- Terraform 1.16.7 (CI pin), AWS 6.72.0 and random 3.9.1, darwin_arm64:
  backend-disabled init/validate and 11 mock-provider cases passed. Initial
  Terraform 1.17.1 checks also passed before the final cases were added.
- Offline plan/config graph proves 13 transitive prerequisites: verifier waits
  for DB/clone, exact IAM/profile and SG paths; clone waits for snapshot, primary,
  parameter and subnet groups. Reverse graph ordering does not prove asynchronous
  native deletion; exact ID checks are required separately.
- TFLint 0.64.0 passed with the repository configuration. terraform-docs 0.24.0
  generated the README table. Formatting and Git whitespace checks passed.
- Checkov 3.3.30 scoped to this root including local modules: 94 passed, 0 failed,
  24 explicit skips. Deliberate single-AZ/short-lived monitoring/logging choices,
  protection-release expression and launch-template inheritance are documented
  inline. This is not a whole-repository scan.
- Real npm ci in this example's own T7 `proof/node_modules`, Node24.22.2;
  pg8.16.3/esbuild0.28.2 and a real package-lock. npm audit found 0 vulnerabilities.
  Node syntax and refusal-class regression passed. JavaScript is used here;
  no TypeScript project/typecheck is claimed.
- 13 Python offline tests passed: complete/invalid/foreign pagination, exact
  version-ledger cleanup, unknown-key/upload refusal before mutation, wrong
  native/credential error rejection and version/digest/source/path-bound archive
  extraction using a stub AWS command only. Python AST and Bash syntax passed.
- Committed-source payload builds must run twice and match exactly; the builder
  refuses any dirty worktree. It bundles pg and the host verifier, with a source,
  lock and per-file digest manifest. Exact artifact size/hash belongs in the PR
  evidence after committing the final reviewed source. It is unsigned and not
  a distributable application/provider artifact.

No cloud availability, IAM enforcement/propagation, private connectivity, actual
CA digest, managed secret history, PostgreSQL extensions/ACL, RDS snapshot restore,
S3 runtime behavior, or teardown success follows from these source checks.
Retained automated backups, service-created ENIs, managed-secret retirement,
complete S3 versions/markers/multipart capture and both compute lifetimes require
native evidence. Missing/foreign/Denied/partial state blocks a clean result.
