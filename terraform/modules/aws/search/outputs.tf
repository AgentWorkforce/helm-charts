output "domain_name" {
  description = "Domain name."
  value       = aws_opensearch_domain.this.domain_name
}

output "domain_arn" {
  description = "Domain ARN."
  value       = aws_opensearch_domain.this.arn
}

output "endpoint" {
  description = "Private VPC HTTPS endpoint host (no scheme). The future sessions-pipeline OpenSearch search backend's URL is https://<endpoint>; no chart value consumes it yet (see the README)."
  value       = aws_opensearch_domain.this.endpoint
}

output "url" {
  description = "https://<endpoint>."
  value       = "https://${aws_opensearch_domain.this.endpoint}"
}

output "dashboard_endpoint" {
  description = "OpenSearch Dashboards host inside the VPC."
  value       = aws_opensearch_domain.this.dashboard_endpoint
}

output "indexer_role_arn" {
  description = "Indexer workload role (Pod Identity). Map it to an OpenSearch role with write permissions on the transcript indices (backend_roles) using the master user."
  value       = try(aws_iam_role.workload["indexer"].arn, null)
}

output "reader_role_arn" {
  description = "Read API workload role (Pod Identity). Map it to an OpenSearch role with read permissions on the transcript indices."
  value       = try(aws_iam_role.workload["reader"].arn, null)
}

output "pod_identity_association_ids" {
  description = "Pod Identity associations created, keyed by role/cluster/namespace/service-account."
  value       = { for k, v in aws_eks_pod_identity_association.workload : k => v.association_id }
}

output "indexer_policy_json" {
  description = "The indexer's IAM policy, to attach to an existing role (EKS Pod Identity allows one role per ServiceAccount, so a pod that already has a role gets this policy on that role)."
  value       = local.policies["indexer"]
}

output "reader_policy_json" {
  description = "The reader's IAM policy, to attach to an existing role."
  value       = local.policies["reader"]
}
