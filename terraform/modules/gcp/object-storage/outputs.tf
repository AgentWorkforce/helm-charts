output "bucket_name" {
  description = "Bucket name. Feeds sessions-pipeline worker.locker.bucket and alleyoop.locker.bucket (provider gcs, endpoint \"\"), or durable-actors storage.bucket."
  value       = google_storage_bucket.this.name
}

output "bucket_url" {
  description = "gs://<bucket>."
  value       = google_storage_bucket.this.url
}

output "location" {
  description = "Bucket location. Feeds worker.locker.region / alleyoop.locker.region when it is a region."
  value       = lower(google_storage_bucket.this.location)
}

output "google_service_account_email" {
  description = "Workload Google service account (null unless workload_identity.google_service_account is set). Annotate the Kubernetes service accounts iam.gke.io/gcp-service-account=<email>; durable-actors takes it as serviceAccount.googleServiceAccount."
  value       = try(google_service_account.workload[0].email, null)
}
