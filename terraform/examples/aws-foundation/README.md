# AWS foundation root

Source-only first layer. Read the [module scope, identity, KMS and lifecycle contract](../../modules/aws/foundation) before any execution plan. No cloud resource has been created by this example. Account, region, versions, operator roles/networks, key policy and subnet availability require separate review.

1. Copy `terraform.tfvars.example` to an ignored local input file and replace every placeholder. Use an existing AWS account and durable customer-managed KMS key. No credentials or secret values belong in inputs.
2. Copy `backend.hcl.example` to an ignored/operator-owned backend file. The pre-existing versioned/encrypted state bucket must survive foundation/data/application retirement. Use separate account/region/environment/layer keys, native S3 locking (`use_lockfile=true`) and bucket access limited to the intended operator; backend credentials come from the environment. Backend `allowed_account_ids` independently fences the backend account. A separate backend account is valid when explicitly reviewed.
3. Validate without a backend or cloud credentials: `terraform init -backend=false`, `terraform validate`, `terraform test`. Tests use synthetic mock-only versions and IDs. For a later approved execution, initialize the reviewed S3 backend and credentials, then review a saved plan. Do not run a live plan/apply based on synthetic test defaults.
4. Hand the non-secret `data_environment_inputs` object to a separately initialized `aws-environments` state as explicit inputs. It intentionally omits the search admin role and Lambda package. Do not point data or application at the foundation state key. StorageClass and actor outputs are application manifests/values to apply later with exec authentication.

Example key layout: `<existing-account>/<region>/<environment>/foundation/terraform.tfstate`, then separate `data/terraform.tfstate` and `application/terraform.tfstate`. The backend does not read root variables: replace its placeholders independently. Customer/Pippen identities and resource names must be checked against both the state key and target account.

Foundation provides infrastructure prerequisites for the full suite, including Lambda networking and first-party Terse placement. It does not install Helm charts, a Lambda handler, secrets, DNS/certificates, auth services or application data. Existing proof resources are out of scope and remain running.

<!-- BEGIN_TF_DOCS -->
### Requirements

| Name | Version |
| ---- | ------- |
| terraform | >= 1.10 |
| aws | >= 6.72, < 7.0 |

### Modules

| Name | Source | Version |
| ---- | ------ | ------- |
| foundation | ../../modules/aws/foundation | n/a |

### Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| account\_id | Exact existing target account; independently checked against the caller. | `string` | n/a | yes |
| actor\_availability\_zone | Single approved actor-host AZ, matching durable-actors placement.zone; no HA claim. | `string` | n/a | yes |
| addon\_versions | Explicit compatible versions for vpc-cni, kube-proxy, coredns, eks-pod-identity-agent and aws-ebs-csi-driver. | `map(string)` | n/a | yes |
| environment | Environment slug shared with the data root. | `string` | n/a | yes |
| kms\_key\_arn | Existing durable same-account/region symmetric KMS key for cluster secrets, logs and EBS; key policy/grants are external. | `string` | n/a | yes |
| kubernetes\_version | Required region-supported EKS minor version, verified by the execution plan. No latest default. | `string` | n/a | yes |
| node\_ami\_release\_version | Explicit compatible AL2023 x86\_64 EKS AMI release, pinned by execution packet. | `string` | n/a | yes |
| operator\_role\_arns | Existing same-account IAM operator roles granted EKS cluster-admin access explicitly; no implicit creator admin. | `set(string)` | n/a | yes |
| region | Explicit AWS commercial region. | `string` | n/a | yes |
| subnets | Two or three unique AZ names mapped to non-overlapping public/private CIDRs within the VPC. | `map(object({ public_cidr = string, private_cidr = string }))` | n/a | yes |
| actor\_capacity | Dedicated first-party actor managed-node sizing; single AZ. | `object({ min = number, desired = number, max = number })` | ```{ "desired": 1, "max": 2, "min": 1 }``` | no |
| actor\_instance\_type | Region-supported x86\_64 first-party actor-host node instance type. | `string` | `"m6i.large"` | no |
| capacity | General managed-node sizing; node count alone does not provide application HA. | `object({ min = number, desired = number, max = number })` | ```{ "desired": 2, "max": 4, "min": 2 }``` | no |
| deletion\_protection | EKS API deletion protection; disable only through a reviewed retirement change. | `bool` | `true` | no |
| instance\_type | Region-supported x86\_64 AL2023 general node instance type. | `string` | `"m6i.large"` | no |
| name\_prefix | Product prefix; combined name must fit the data-layer contract. | `string` | `"agent-relay"` | no |
| namespace | Application namespace reference only; null exports agent-relay-environment. | `string` | `null` | no |
| operator\_cidrs | Approved IPv4 operator networks; private reachability is still required by default. Public API requires /8 or narrower. | `list(string)` | `[]` | no |
| operator\_security\_group\_ids | Existing operator/proof-runner SGs in this VPC or connected networks; only API HTTPS ingress is granted. | `set(string)` | `[]` | no |
| pippen | Expected allocated lease agent/session from Pippen; exact STS session caller is enforced. No credentials. | `object({ agent = string, session_id = string })` | `null` | no |
| public\_api\_enabled | Opt in to public EKS API only with explicit bounded operator CIDRs. | `bool` | `false` | no |
| release\_name | Helm release reference used for ServiceAccount names; creates no Kubernetes objects. | `string` | `"agent-relay"` | no |
| search\_az\_count | Number of private AZs exported to OpenSearch: 1, 2 or 3. | `number` | `2` | no |
| tags | Additional tags; reserved environment/Pippen identity cannot be overridden. | `map(string)` | `{}` | no |
| vpc\_cidr | Non-overlapping IPv4 VPC range approved by the operator. | `string` | `"10.80.0.0/16"` | no |

### Outputs

| Name | Description |
| ---- | ----------- |
| actor\_profile | First-party durable-actors placement/sandbox values. |
| cluster\_security\_group\_id | Service-created SG identifier for scoped retirement inventory. |
| data\_environment\_inputs | Non-secret subset of inputs for a separately initialized aws-environments state. |
| identity\_references | References for separately owned workload roles. |
| storage\_class\_manifest | Retained encrypted CSI class to apply in application state. |
<!-- END_TF_DOCS -->
