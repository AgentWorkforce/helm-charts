# Plans the whole example with every add-on on, so module wiring (including
# search <-> functions, which reference each other's outputs) stays acyclic.
mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = { account_id = "111111111111", arn = "arn:aws:sts::111111111111:assumed-role/deployer/test" }
  }
  mock_data "aws_region" {
    defaults = { region = "us-west-2" }
  }
  mock_data "aws_partition" {
    defaults = { partition = "aws", dns_suffix = "amazonaws.com" }
  }
  # Realistic values: OpenTofu fills computed attributes at plan time, and
  # the provider validates ARNs.
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::111111111111:role/mock" }
  }
  mock_resource "aws_cloudwatch_log_group" {
    defaults = { arn = "arn:aws:logs:us-west-2:111111111111:log-group:mock" }
  }
  mock_resource "aws_s3_bucket" {
    defaults = { arn = "arn:aws:s3:::relay-sessions", region = "us-west-2" }
  }
  mock_resource "aws_sqs_queue" {
    defaults = { arn = "arn:aws:sqs:us-west-2:111111111111:mock", url = "https://sqs.us-west-2.amazonaws.com/111111111111/mock" }
  }
  mock_resource "aws_secretsmanager_secret" {
    defaults = { arn = "arn:aws:secretsmanager:us-west-2:111111111111:secret:mock" }
  }
  mock_resource "aws_lambda_function" {
    defaults = { arn = "arn:aws:lambda:us-west-2:111111111111:function:mock" }
  }
  mock_resource "aws_cloudwatch_event_rule" {
    defaults = { arn = "arn:aws:events:us-west-2:111111111111:rule/mock" }
  }
  mock_resource "aws_opensearch_domain" {
    defaults = { arn = "arn:aws:es:us-west-2:111111111111:domain/mock", endpoint = "vpc-mock.us-west-2.es.amazonaws.com" }
  }
  mock_resource "aws_db_instance" {
    defaults = {
      address            = "mock.abc.us-west-2.rds.amazonaws.com"
      arn                = "arn:aws:rds:us-west-2:111111111111:db:mock"
      master_user_secret = [{ secret_arn = "arn:aws:secretsmanager:us-west-2:111111111111:secret:rds", kms_key_id = "", secret_status = "active" }]
    }
  }
}

mock_provider "random" {}

variables {
  account_id                  = "111111111111"
  region                      = "us-west-2"
  environment                 = "dev"
  private_subnet_ids          = ["subnet-a", "subnet-b"]
  database_security_group_ids = ["sg-db"]
  search_subnet_ids           = ["subnet-a"]
  search_security_group_ids   = ["sg-search"]
  search_master_user_arn      = "arn:aws:iam::111111111111:role/search-admin"
  eks_cluster_name            = "relay"
}

run "development_composition" {
  command = plan
  assert {
    condition     = output.environment.namespace == "agent-relay-dev" && output.verification.storage.prefix == "proofs/dev/"
    error_message = "Names must isolate the environment, account and region."
  }
  assert {
    condition = toset(keys(module.search.pod_identity_association_ids)) == toset([
      "indexer/relay/agent-relay-dev/agent-relay-search-indexer",
      "reader/relay/agent-relay-dev/agent-relay-session-read",
    ])
    error_message = "Search must use separate environment-scoped indexer and reader identities."
  }
}

run "custom_environment" {
  command = plan
  variables {
    environment       = "team-a"
    environment_class = "staging"
    search_subnet_ids = ["subnet-a", "subnet-b"]
  }
  assert {
    condition     = output.verification.storage.prefix == "proofs/team-a/" && output.environment.namespace == "agent-relay-team-a"
    error_message = "Environment labels are arbitrary slugs, not a fixed dev/prod enumeration."
  }
}

run "production_requires_three_zones" {
  command = plan
  variables { environment_class = "production" }
  expect_failures = [terraform_data.environment_contract]
}

run "production_cannot_disable_database_protection" {
  command = plan
  variables {
    environment_class   = "production"
    search_subnet_ids   = ["subnet-a", "subnet-b", "subnet-c"]
    deletion_protection = false
  }
  expect_failures = [terraform_data.environment_contract]
}

run "production_composition" {
  command = plan
  variables {
    environment       = "prod"
    environment_class = "production"
    search_subnet_ids = ["subnet-a", "subnet-b", "subnet-c"]
  }
  assert {
    condition     = output.environment.class == "production" && output.verification.storage.prefix == "proofs/prod/"
    error_message = "Production verification must use its own environment marker prefix."
  }
}

run "wrong_account_refused" {
  command = plan
  variables { account_id = "222222222222" }
  expect_failures = [terraform_data.environment_contract]
}

run "aurora_requires_explicit_version_and_class" {
  command = plan
  variables { postgres_engine_mode = "aurora" }
  expect_failures = [terraform_data.environment_contract]
}

run "pippen_wrong_session_refused" {
  command = plan
  variables {
    name_prefix = "pippen-sbx-ar"
    pippen      = { agent = "aws-proof", session_id = "wrong-session" }
  }
  expect_failures = [terraform_data.environment_contract]
}

run "exact_pippen_lease_composes" {
  command = plan
  variables {
    name_prefix = "pippen-sbx-ar"
    pippen      = { agent = "aws-proof", session_id = "approved-session" }
  }
  override_data {
    target = data.aws_caller_identity.current
    values = { account_id = "111111111111", arn = "arn:aws:sts::111111111111:assumed-role/agent-session/agent-approved-session" }
  }
  assert {
    condition     = output.verification.storage.prefix == "proofs/dev/"
    error_message = "The exact Pippen lease must be able to plan the environment."
  }
}

run "reserved_tags_refused" {
  command = plan
  variables { tags = { "pippen:sandbox" = "true" } }
  expect_failures = [var.tags]
}

run "overlong_resource_prefix_refused" {
  command = plan
  variables { name_prefix = "agent-relay-very-long" }
  expect_failures = [terraform_data.environment_contract]
}

run "lambda_composition" {
  command = plan
  variables {
    pipeline_runtime            = "lambda"
    lambda_package              = { s3_bucket = "reviewed-artifacts", s3_key = "pipeline.zip", s3_object_version = "reviewed-version" }
    function_security_group_ids = ["sg-function"]
    enable_relayfile            = true
  }
  assert {
    condition     = length(module.pipeline) == 1 && output.application_contract.pipeline_runtime == "lambda" && output.application_contract.overlapping_pipeline_workers_must_be_disabled
    error_message = "Lambda mode must create its runtime and explicitly require overlapping worker stages to be disabled."
  }
  assert {
    condition     = alltrue(values(output.application_contract.components))
    error_message = "The full-suite contract includes control API, dashboard, pipeline, History, Relaycast, auth, Terse and optional Relayfile."
  }
  assert {
    condition     = !output.pipeline.activation_enabled && output.application_contract.hoopdb_bootstrap_profile == "private-reachable-managed-postgres-required"
    error_message = "Lambda must start inactive and require a privately reachable managed-Postgres bootstrap profile."
  }
}

run "mutable_null_s3_version_refused" {
  command = plan
  variables {
    pipeline_runtime            = "lambda"
    lambda_package              = { s3_bucket = "reviewed-artifacts", s3_key = "pipeline.zip", s3_object_version = "null" }
    function_security_group_ids = ["sg-function"]
  }
  expect_failures = [terraform_data.environment_contract]
}

run "runtime_cannot_be_search_admin" {
  command = plan
  variables { search_master_user_arn = "arn:aws:iam::111111111111:role/agent-relay-dev-session-pipeline" }
  expect_failures = [terraform_data.environment_contract]
}

run "storage_worker_cannot_be_search_admin" {
  command = plan
  variables { search_master_user_arn = "arn:aws:iam::111111111111:role/agent-relay-dev-sessions" }
  expect_failures = [terraform_data.environment_contract]
}

run "lambda_zip_must_be_immutable" {
  command = plan
  variables {
    pipeline_runtime            = "lambda"
    lambda_package              = { s3_bucket = "reviewed-artifacts", s3_key = "pipeline.zip" }
    function_security_group_ids = ["sg-function"]
  }
  expect_failures = [terraform_data.environment_contract]
}
