terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0, < 7.0"
    }
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = var.tags
  }
}

locals {
  # The ServiceAccounts the agent-relay chart creates for the sessions
  # pipeline (<release>-worker, <release>-alleyoop; values-eks.yaml).
  sessions_service_accounts = [
    for sa in ["worker", "alleyoop"] : {
      cluster_name    = var.eks_cluster_name
      namespace       = var.namespace
      service_account = "${var.release_name}-${sa}"
    }
  ]
}

# Postgres for relaycontrol (relay-cloud-api), relayhistory, HoopDb (sessions)
# and, if used, durable-actors. One instance, one database per component.
module "postgres" {
  source = "../../modules/aws/postgres"

  name                   = "${var.name}-pg"
  engine_mode            = var.postgres_engine_mode
  engine_version         = var.postgres_engine_mode == "aurora" ? var.aurora_engine_version : "17"
  subnet_ids             = var.private_subnet_ids
  vpc_security_group_ids = var.database_security_group_ids
  kms_key_arn            = var.kms_key_arn
  tags                   = var.tags
}

# Session objects (Locker), read and written by the worker and alleyoop pods
# through EKS Pod Identity.
module "sessions_bucket" {
  source = "../../modules/aws/object-storage"

  bucket_name = var.sessions_bucket_name
  kms_key_arn = var.kms_key_arn
  access_role = {
    name                      = "${var.name}-sessions"
    pod_identity_associations = local.sessions_service_accounts
  }
  tags = var.tags
}

# Optional: OpenSearch as the transcript search index (replaces ClickHouse;
# the default stays Postgres pg_trgm). Needs the services' OpenSearch backend.
module "search" {
  source = "../../modules/aws/search"
  count  = var.enable_search ? 1 : 0

  domain_name        = "${var.name}-search"
  subnet_ids         = var.search_subnet_ids
  security_group_ids = var.search_security_group_ids
  kms_key_arn        = var.kms_key_arn
  master_user_arn    = var.search_master_user_arn
  # Pod Identity allows one role per ServiceAccount, and the worker and
  # alleyoop ServiceAccounts share the sessions bucket role. Attaching the
  # indexer policy there would give both write access, so no workload grant is
  # made here. Once the services have an OpenSearch backend, attach
  # indexer_policy_json to the indexer's own role and reader_policy_json to the
  # read API's, and list both in additional_principal_arns.
  workload_roles = { create = false }
  tags           = var.tags
}

# Optional: the sessions pipeline's event-driven mode (S3 -> SQS -> Lambda),
# instead of the long-running worker stages.
module "functions" {
  source = "../../modules/aws/functions"
  count  = var.enable_functions ? 1 : 0

  name                   = var.name
  bucket_name            = module.sessions_bucket.bucket_name
  bucket_kms_key_arn     = var.kms_key_arn
  package                = var.pipeline_package
  vpc_subnet_ids         = var.private_subnet_ids
  vpc_security_group_ids = var.function_security_group_ids
  alarm_actions          = var.alarm_actions
  tags                   = var.tags
}
