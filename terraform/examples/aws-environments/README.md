# AWS environments

An environment-aware data stack for self-hosted Agent Relay. It composes RDS
PostgreSQL 17 (or explicitly selected Aurora PostgreSQL), S3, private OpenSearch,
and optionally the sessions-pipeline Lambda/SQS/EventBridge runtime. This is
source preparation for a complete installation: mock tests do **not** prove a
live deployment or application compatibility.

The foundation supplies the private network, EKS, Pod Identity agent, security
groups, administrative runner access, NAT/endpoints, state bucket, KMS grants
and the OpenSearch service-linked role. Foundation and application lifecycle
remain separate from this data state. Foundation automation is tracked in
[helm-charts#59](https://github.com/AgentWorkforce/helm-charts/issues/59).

## Environments and state

Choose any lowercase `environment` slug (up to 16 characters), independently of
its development/staging/production sizing class. The combined
`name_prefix-environment` must fit in 21 characters. Resources, namespace,
verification markers and tags are environment-scoped. Use a unique prefix or
environment name for every installation in the same account/region.

| Class | RDS | Backups | OpenSearch |
|---|---|---|---|
| development | t4g.micro, 20 GiB, single AZ | 7 days | one t3.small node, 20 GiB |
| staging | t4g.medium, 100 GiB, Multi-AZ | 14 days | one node per supplied AZ, m7g.large, 100 GiB |
| production | r7g.large, 100 GiB, Multi-AZ | 35 days | three r7g.large data nodes, dedicated masters, Multi-AZ standby, 200 GiB |

Production refuses database deletion protection being disabled and requires
three distinct search subnets in three AZs. The foundation must verify their
actual AZs; distinct IDs alone cannot establish AZ placement. Aurora requires
an explicit region-supported engine version and compatible instance class;
RDS live proof does not qualify Aurora.

Copy a matching pair from `profiles/` into an approved private directory and
replace every placeholder. Keep the JSON files uncommitted, with mode 0600.
The runner requires encrypted S3 state with native locking and an exact expected
bucket owner. Keys must end in:

```text
/<account_id>/<region>/<environment>/data.tfstate
```

Foundation and application state use different keys. CLI workspaces are not
used: the runner refuses both an environment-selected workspace and a cached
non-default workspace. Credentials belong to the approved runner, never backend
JSON, Terraform variables, values files or command output. State and saved plans
contain operational metadata and must remain private even without passwords.

## Review and apply

From the repository root, under the intended customer's AWS identity:

```sh
python3 terraform/scripts/aws-environment.py plan \
  --variables /approved/private/dev.tfvars.json \
  --backend /approved/private/dev.backend.json
python3 terraform/scripts/aws-environment.py show \
  --variables /approved/private/dev.tfvars.json \
  --backend /approved/private/dev.backend.json
```

Review the saved plan and its account, region, environment, resource inventory,
cost, retention and networking. After approval of that exact plan, run `apply`
with the same arguments and `--approve-plan <saved-plan-SHA-256>`. The receipt
binds the variables, backend, Terraform source, dependency lock files, runner
and local Lambda artifact bytes. Changed bindings require a new plan. Successful
apply consumes the receipt. Provider credentials refresh through the runner's
normal SDK credential chain; the provider also fences the allowed account.

Use `output` with the same arguments to export **only** non-secret verification
references to `terraform/.runs/<account>/<region>/<environment>/verification.json`.
`TF_BIN=tofu` selects OpenTofu; use one reviewed tool/version and dependency lock
for the lifecycle. The committed lock is for Terraform. OpenTofu rewrites
implicit provider registry addresses and uses different package checksums;
initialize and review that tool's converted lock in a separate checkout before
using the runner. A Terraform lock cannot simply be used read-only with
OpenTofu. Normal runner operations require a reviewed, tool-compatible lock and
never upgrade providers implicitly. The runner exposes no destroy command.

### Pippen sandbox execution

Pippen allocates/leases/sweeps AWS accounts; these Terraform files create the
product infrastructure. Reuse the assigned account and certificate identity.
Follow the Pippen owner's current runbook for `sandbox up` and `status`, then set
the returned account/session and agent in `pippen`, and use a prefix such as
`pippen-sbx-ar`. Every product invocation runs under refreshing credentials:

```sh
pippen sandbox exec aws-proof -- \
  python3 terraform/scripts/aws-environment.py plan \
  --variables /approved/private/dev.tfvars.json \
  --backend /approved/private/dev.backend.json
```

Use the same wrapper for show/apply/output. The runner verifies Pippen's exported
account/agent/session and exact STS caller. Roles use `/pippen/workload/`, the
Pippen boundary, reserved tags and bucket prefix. No fallback to an admin role
is provided. Before live use the Pippen owner must confirm the deployed boundary
and sweeper support RDS, OpenSearch, Lambda/SQS/EventBridge and the foundation
resources. Existing S3-only or mock proof does not establish that support.

The state bucket must outlive inner stack teardown. Preserve approved recovery
data, state and receipts outside any session prefix Pippen will sweep. Never
delete the baseline workspace bucket. End with the owner-run Pippen sweep and a
`clean: true` receipt; investigate quarantine rather than bypassing it. Pippen
currently supplies AWS sandboxes, not GCP project vending.

## Lambda bootstrap and the complete application

Worker mode is the default. Lambda mode requires `pipeline_runtime = "lambda"`,
private function security groups, and exactly one compatible immutable package:
a digest-pinned ECR Lambda image, a **versioned** S3 ZIP (not the mutable `null`
version), or a local ZIP with its base64 SHA-256. [`profiles/lambda.tfvars.json.example`](profiles/lambda.tfvars.json.example)
shows an additive fragment to merge into an environment file. The Lambda module
uses Node 24/arm64 for ZIPs; a Bun services image is not a Lambda handler package.

`activate_lambda` defaults to false, disabling the queue event source mapping
and both schedules. The queue and bucket notification still exist and can
accumulate messages. Direct authorized invocation remains possible. Before a
separate reviewed activation plan:

1. Verify package provenance, handler/schema assets, TLS support and actual
   provider adapter dispatch in the deployed pipeline **and** read API.
2. Complete a managed-RDS-compatible HoopDb bootstrap, with distinct owner and
   runtime credentials, extension/ACL convergence and generation checks. The
   existing true-superuser CNPG bootstrap is not an RDS bootstrap. Lambda cannot
   reach a Kubernetes-only CNPG Service merely by sharing a VPC.
3. Populate the pipeline's empty secret out of band, using runtime credentials.
   Never use the RDS master account as an application credential.
4. Configure OpenSearch fine-grained permissions for distinct indexer, Lambda
   writer and reader roles. The temporary proof mappings below are not the
   application's permanent security configuration.
5. Disable overlapping reconcile/referee/cost-sweep worker stages, account for
   queued messages, and verify no second pipeline owner will run. Lambda is an
   alternative for those stages; the remaining application workers still run.

The `application_contract` output records the required full suite:
relaycontrol API, relay-dashboard, sessions-pipeline, relayhistory, Relaycast
backed by first-party Terse/durable-actors, RelayAuth, and optional Relayfile.
It is not a deployable Helm overlay. Actor placement/runtime identities, actor
storage buckets, component databases and Secrets, Redis where required,
DNS/TLS, authentication and application wiring still belong in the reviewed
foundation/application installation. ServiceAccount outputs must match actual
chart component identities; creating Pod Identity associations alone grants no
running workload the intended binding.

## Live verification

Use an approved private Linux/macOS runner with refreshed AWS credentials, network access,
`boto3` and `psycopg[binary]`. The verifier reads Secrets Manager only in memory
for PostgreSQL and prints bounded receipts without URLs or secret values.
Choose one random run ID (`python3 -c 'import uuid; print(uuid.uuid4().hex)'`) and
use it for every phase:

```sh
python3 terraform/scripts/verify-aws-data.py configuration \
  --config /approved/private/verification.json --run-id <32-hex-run-id> \
  --confirm-account <account> --confirm-environment dev --confirm-live
```

Run `postgres` with `--rds-ca /approved/rds-global-bundle.pem` to require real
PostgreSQL 17, private RDS metadata, encryption/backups/protection and
`sslmode=verify-full`, then a temporary-table round trip. Run `storage` under the
storage role for synthetic put/get/list/delete. Version history is retained.

Run `search-bootstrap` as the separate administrator, `search-write` as the
indexer, `search-read` as the reader, then `search-cleanup` as the administrator,
each with the same arguments and run ID. These phases create temporary scoped
FGAC roles/mappings and two synthetic indices, verify the marker, reject both
single and bulk reader writes, reject access to a known foreign index, and
check the rejected writes had no effects before cleanup. Signed requests never
follow redirects. Keep cleanup failures visible and retain the run ID so the
exact synthetic resources can be retired later.

`lambda-smoke` checks the deployed arm64/private-VPC artifact and explicitly
invokes reconcile. ZIPs also need the reviewed `--lambda-code-sha256`. An invoke
HTTP 200 with `FunctionError` fails. This proves initialization/reconcile only;
the complete proof must additionally upload a synthetic session through the
real courier, follow S3 notification -> SQS -> Lambda -> RDS/OpenSearch -> read
API, and verify tenant/lease isolation, partial failures, DLQ/replay,
idempotence, all required application components, optional Relayfile on/off,
backup/restore, upgrade and clean retirement. Resource creation and a successful
smoke invocation are not full application proof.

Do not tear down an existing environment until ownership and a current
consistent recovery set are recorded. RDS deletion protection, final snapshots,
versioned non-empty S3 and the search module's `prevent_destroy` intentionally
block casual destruction. Any retirement needs a reviewed protection change,
exact destroy inventory and recovery proof; do not remove state to bypass them.

<!-- BEGIN_TF_DOCS -->
### Requirements

| Name | Version |
| ---- | ------- |
| terraform | >= 1.11 |
| aws | >= 6.0, < 7.0 |

### Providers

| Name | Version |
| ---- | ------- |
| aws | >= 6.0, < 7.0 |
| terraform | n/a |

### Modules

| Name | Source | Version |
| ---- | ------ | ------- |
| pipeline | ../../modules/aws/functions | n/a |
| postgres | ../../modules/aws/postgres | n/a |
| search | ../../modules/aws/search | n/a |
| sessions\_bucket | ../../modules/aws/object-storage | n/a |

### Resources

| Name | Type |
| ---- | ---- |
| [terraform_data.environment_contract](https://registry.terraform.io/providers/hashicorp/terraform/latest/docs/resources/data) | resource |
| [aws_caller_identity.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/caller_identity) | data source |

### Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| account\_id | Exact target AWS account. The provider refuses any other account. Use the allocated account from Pippen in sandbox mode. | `string` | n/a | yes |
| database\_security\_group\_ids | Database security groups allowing PostgreSQL only from the approved application/proof runner. | `list(string)` | n/a | yes |
| eks\_cluster\_name | Existing EKS cluster for Pod Identity; the foundation root owns the cluster. | `string` | n/a | yes |
| environment | Unique environment slug, e.g. dev, staging, production or team-a. It scopes resource names, tags, the namespace and the verification prefix. | `string` | n/a | yes |
| private\_subnet\_ids | Existing private database subnets in at least two AZs. The foundation stack owns VPC/subnets/routes. | `list(string)` | n/a | yes |
| region | AWS region for this environment. | `string` | n/a | yes |
| search\_master\_user\_arn | Existing environment-specific IAM administrator for OpenSearch role bootstrap. Never a runtime role. | `string` | n/a | yes |
| search\_security\_group\_ids | Search security groups allowing HTTPS only from approved application/proof runner identities. | `list(string)` | n/a | yes |
| search\_subnet\_ids | Existing private OpenSearch subnets, one per AZ. Production requires three. | `list(string)` | n/a | yes |
| activate\_lambda | Enable automatic Lambda queue/schedule processing after secret/bootstrap/artifact checks and after disabling overlapping worker stages. | `bool` | `false` | no |
| aurora\_engine\_version | Explicit region-supported Aurora PostgreSQL 17 minor version when Aurora is selected. | `string` | `null` | no |
| database\_instance\_class | Override the environment tier's instance class. Aurora needs an Aurora-supported class. | `string` | `null` | no |
| deletion\_protection | Database API deletion protection. Production refuses false. Final snapshots and S3 versioning remain enabled. | `bool` | `true` | no |
| enable\_relayfile | Include Relayfile in the full-suite application contract; its actor identities/Secrets must be configured by the application layer. | `bool` | `false` | no |
| environment\_class | Sizing/protection tier; environment names remain independent of this classification. | `string` | `"development"` | no |
| function\_security\_group\_ids | Lambda security groups with private database/search access and egress to the required AWS services. | `list(string)` | `[]` | no |
| kms\_key\_arn | Existing customer-managed key; null uses AWS-managed encryption keys. | `string` | `null` | no |
| lambda\_package | Compatible pipeline artifact when pipeline\_runtime=lambda: exactly one immutable image, versioned S3 zip, or local zip with hash. No credential values. | ```object({ image_uri = optional(string) s3_bucket = optional(string) s3_key = optional(string) s3_object_version = optional(string) filename = optional(string) source_code_hash = optional(string) })``` | `null` | no |
| name\_prefix | Product prefix. prefix-environment must be at most 21 characters. For Pippen use e.g. pippen-sbx-ar. | `string` | `"agent-relay"` | no |
| namespace | Environment namespace; null uses agent-relay-<environment>. | `string` | `null` | no |
| pipeline\_runtime | workers or lambda. Lambda requires its own compatible immutable handler artifact; application deployment must disable overlapping worker stages. | `string` | `"workers"` | no |
| pippen | Pippen lease identity from sandbox status/exec. null for customer accounts. No credentials belong here. | ```object({ agent = string session_id = string })``` | `null` | no |
| postgres\_engine\_mode | rds or aurora. Aurora requires an explicit full engine version and separate live validation. | `string` | `"rds"` | no |
| release\_name | Helm release name used in generated ServiceAccount names. | `string` | `"agent-relay"` | no |
| search\_engine\_version | Region-supported OpenSearch engine version. | `string` | `"OpenSearch_2.19"` | no |
| search\_instance\_type | Override the environment tier's OpenSearch data node type. | `string` | `null` | no |
| tags | Additional resource tags. Environment identity and Pippen conventions cannot be overridden. | `map(string)` | `{}` | no |

### Outputs

| Name | Description |
| ---- | ----------- |
| application\_contract | Required full-suite components and selected pipeline mode. This contract does not replace complete Helm values, actor roles, bootstrap or runtime compatibility proof. |
| environment | Environment identity to compare with the separately configured backend before apply. |
| pipeline | Lambda runtime bindings, or null in worker mode. Populate the secret out of band and verify actual handler compatibility before activation. |
| service\_accounts | Distinct environment-scoped workload bindings; the application chart must use these identities. |
| verification | Non-secret input for the private-runner data-path verifier. Contains secret references, never secret values. |
<!-- END_TF_DOCS -->
