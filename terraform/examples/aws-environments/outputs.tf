output "environment" {
  description = "Environment identity to compare with the separately configured backend before apply."
  value       = { name = var.environment, class = var.environment_class, account_id = var.account_id, region = var.region, namespace = local.namespace }
}

output "verification" {
  description = "Non-secret input for the private-runner data-path verifier. Contains secret references, never secret values."
  value = {
    environment = var.environment
    account_id  = var.account_id
    region      = var.region
    postgres = {
      host                  = module.postgres.host
      port                  = module.postgres.port
      database              = module.postgres.initial_database
      secret_arn            = module.postgres.master_user_secret_arn
      resource_arn          = module.postgres.resource_arn
      engine_mode           = module.postgres.engine_mode
      deletion_protection   = var.deletion_protection
      backup_retention_days = local.profile.backups
    }
    storage = {
      bucket   = module.sessions_bucket.bucket_name
      prefix   = local.storage_prefix
      role_arn = module.sessions_bucket.access_role_arn
    }
    search = {
      url              = module.search.url
      domain_name      = module.search.domain_name
      domain_arn       = module.search.domain_arn
      master_role_arn  = var.search_master_user_arn
      indexer_role_arn = local.indexer_role_arn
      reader_role_arn  = local.reader_role_arn
      lambda_role_arn  = var.pipeline_runtime == "lambda" ? module.pipeline[0].execution_role_arn : null
      index_prefix     = "${local.name}-"
    }
    pipeline = var.pipeline_runtime == "lambda" ? {
      function_arn = module.pipeline[0].function_arn
      image_uri    = try(var.lambda_package.image_uri, null)
    } : null
  }
}

output "pipeline" {
  description = "Lambda runtime bindings, or null in worker mode. Populate the secret out of band and verify actual handler compatibility before activation."
  value = var.pipeline_runtime == "lambda" ? {
    function_name      = module.pipeline[0].function_name
    activation_enabled = module.pipeline[0].activation_enabled
    function_arn       = module.pipeline[0].function_arn
    queue_url          = module.pipeline[0].queue_url
    dlq_url            = module.pipeline[0].dlq_url
    secret_arn         = module.pipeline[0].secret_arn
  } : null
}

output "application_contract" {
  description = "Required full-suite components and selected pipeline mode. This contract does not replace complete Helm values, actor roles, bootstrap or runtime compatibility proof."
  value = {
    pipeline_runtime = var.pipeline_runtime
    components = {
      cloudApi         = true
      dashboard        = true
      sessionsPipeline = true
      relayhistory     = true
      relaycast        = true
      relayauth        = true
      durableActors    = true
      relayfile        = var.enable_relayfile
    }
    relaycast_backend                             = "durable-actors"
    hoopdb_bootstrap_profile                      = var.pipeline_runtime == "lambda" ? "private-reachable-managed-postgres-required" : "selfhosted-cloudnativepg"
    overlapping_pipeline_workers_must_be_disabled = var.pipeline_runtime == "lambda"
  }
}

output "service_accounts" {
  description = "Distinct environment-scoped workload bindings; the application chart must use these identities."
  value = {
    namespace = local.namespace
    storage   = ["${var.release_name}-worker", "${var.release_name}-alleyoop"]
    indexer   = local.search_indexer_sa
    reader    = local.search_reader_sa
  }
}

output "runtime_role_policy_json" {
  description = "Proposed search and Lambda runtime permissions for operator review. External mode does not attach them or validate existing IAM configuration. Values may be unknown until service resources exist."
  value = {
    indexer  = module.search.indexer_policy_json
    reader   = module.search.reader_policy_json
    pipeline = var.pipeline_runtime == "lambda" ? module.pipeline[0].execution_role_policy_json : null
  }
}

output "lambda_shared_environment" {
  description = "Non-secret writer/reader bindings, or null until explicitly configured. Independently qualify the matching reader artifact, read-only DB identity, JWT settings, schema/FGAC bootstrap and worker retirement before activation."
  value       = var.lambda_runtime_bindings == null ? null : local.lambda_shared_environment
}
