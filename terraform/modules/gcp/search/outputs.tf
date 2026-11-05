output "url" {
  description = "In-cluster HTTPS endpoint. The future sessions-pipeline OpenSearch search backend's URL; no chart value consumes it yet (see the README). Trust the operator-generated CA from the <name>-http-cert Secret (ca.crt)."
  value       = "https://${var.name}.${var.namespace}.svc:9200"
}

output "namespace" {
  description = "Cluster namespace."
  value       = kubernetes_namespace_v1.this.metadata[0].name
}

output "service_name" {
  description = "Cluster Service name."
  value       = var.name
}

output "service_account_name" {
  description = "Kubernetes service account the OpenSearch pods run as (bind it to a Google service account for GCS snapshots)."
  value       = local.service_account
}

output "cluster_release_name" {
  description = "Helm release name of the cluster chart."
  value       = helm_release.cluster.name
}
