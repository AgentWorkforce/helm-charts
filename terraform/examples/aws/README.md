# examples/aws

A thin root that composes the four AWS modules for one agent-relay install on an existing EKS cluster and VPC:

- `aws/postgres` (RDS by default; `postgres_engine_mode = "aurora"`).
- `aws/object-storage` for the sessions Locker, with Pod Identity for `<release>-worker` and `<release>-alleyoop`.
- `aws/search` (`enable_search`). No workload grant is made: the worker and alleyoop share the sessions role (Pod Identity allows one role per ServiceAccount), so attaching the indexer policy there would give both write access. The `search` output carries the indexer and reader policies to attach to dedicated roles once the services have an OpenSearch backend.
- `aws/functions` (`enable_functions`).

```sh
cp terraform.tfvars.example terraform.tfvars   # fill in existing IDs
terraform init && terraform plan
```

`chart_values` prints the non-secret values for `values-eks.yaml`. The database URLs go into the release Secret after the bootstrap in [`terraform/README.md`](../../README.md#postgres-bootstrap-before-the-first-migrate).

<!-- BEGIN_TF_DOCS -->
### Requirements

| Name | Version |
| ---- | ------- |
| terraform | >= 1.6 |
| aws | >= 6.0, < 7.0 |

### Modules

| Name | Source | Version |
| ---- | ------ | ------- |
| functions | ../../modules/aws/functions | n/a |
| postgres | ../../modules/aws/postgres | n/a |
| search | ../../modules/aws/search | n/a |
| sessions\_bucket | ../../modules/aws/object-storage | n/a |

### Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| database\_security\_group\_ids | Existing security groups for Postgres (5432 from the EKS nodes/pods). | `list(string)` | n/a | yes |
| eks\_cluster\_name | Existing EKS cluster that runs agent-relay (Pod Identity associations). | `string` | n/a | yes |
| private\_subnet\_ids | Existing private subnets (two or more AZs) for the database and the function. | `list(string)` | n/a | yes |
| region | AWS region. | `string` | n/a | yes |
| sessions\_bucket\_name | Globally unique S3 bucket name for session objects. | `string` | n/a | yes |
| alarm\_actions | SNS topics for the pipeline alarms. | `list(string)` | `[]` | no |
| aurora\_engine\_version | Aurora PostgreSQL version when postgres\_engine\_mode is aurora. | `string` | `"17.9"` | no |
| enable\_functions | Create the optional event-driven pipeline (Lambda). | `bool` | `false` | no |
| enable\_search | Create the optional OpenSearch domain. | `bool` | `false` | no |
| function\_security\_group\_ids | Existing security groups for the pipeline function ENIs. | `list(string)` | `[]` | no |
| kms\_key\_arn | Customer managed KMS key for Postgres, the sessions bucket and OpenSearch (null: AWS managed keys). The optional pipeline keeps its module defaults (SQS-managed SSE, AWS managed keys); pass the functions module's *\_kms\_key\_arn inputs to change that. | `string` | `null` | no |
| name | Name prefix for every resource (lowercase; at most 21 characters, so <name>-search fits OpenSearch's 28). | `string` | `"agent-relay"` | no |
| namespace | agent-relay release namespace. | `string` | `"agent-relay"` | no |
| pipeline\_package | Pipeline Lambda package (see modules/aws/functions). | ```object({ image_uri = optional(string) s3_bucket = optional(string) s3_key = optional(string) s3_object_version = optional(string) filename = optional(string) source_code_hash = optional(string) })``` | `{}` | no |
| postgres\_engine\_mode | rds or aurora. | `string` | `"rds"` | no |
| release\_name | agent-relay Helm release name. | `string` | `"agent-relay"` | no |
| search\_master\_user\_arn | IAM role that administers OpenSearch fine-grained access control. | `string` | `null` | no |
| search\_security\_group\_ids | Existing security groups for OpenSearch (443 from the indexer and read API). | `list(string)` | `[]` | no |
| search\_subnet\_ids | Existing private subnets for OpenSearch (one per AZ, 2 or 3). | `list(string)` | `[]` | no |
| tags | Tags for every resource (provider default\_tags). | `map(string)` | `{}` | no |

### Outputs

| Name | Description |
| ---- | ----------- |
| chart\_values | Non-secret agent-relay chart values (values-eks.yaml) these resources feed. Database URLs go in the release Secret, not here; see terraform/README.md. |
| functions | Pipeline function, queue, DLQ and secret (null unless enable\_functions). |
| postgres | Postgres host, port, master secret and URL template. |
| search | OpenSearch endpoint and the workload policies to attach (null unless enable\_search). |
| sessions\_role\_arn | Pod Identity role for the worker and alleyoop ServiceAccounts. |
<!-- END_TF_DOCS -->
