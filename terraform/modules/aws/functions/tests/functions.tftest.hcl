mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = { account_id = "111111111111" }
  }
  mock_data "aws_region" {
    defaults = { region = "us-west-2" }
  }
  mock_data "aws_partition" {
    defaults = { partition = "aws", dns_suffix = "amazonaws.com" }
  }
  mock_resource "aws_sqs_queue" {
    defaults = {
      arn = "arn:aws:sqs:us-west-2:111111111111:relay-session-events"
      url = "https://sqs.us-west-2.amazonaws.com/111111111111/relay-session-events"
    }
  }
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::111111111111:role/relay-session-pipeline" }
  }
  mock_resource "aws_cloudwatch_log_group" {
    defaults = { arn = "arn:aws:logs:us-west-2:111111111111:log-group:/aws/lambda/relay-session-pipeline" }
  }
  mock_resource "aws_secretsmanager_secret" {
    defaults = { arn = "arn:aws:secretsmanager:us-west-2:111111111111:secret:relay/session-pipeline-abc" }
  }
  mock_resource "aws_lambda_function" {
    defaults = { arn = "arn:aws:lambda:us-west-2:111111111111:function:relay-session-pipeline" }
  }
  mock_resource "aws_cloudwatch_event_rule" {
    defaults = { arn = "arn:aws:events:us-west-2:111111111111:rule/relay-session-reconcile" }
  }
}

variables {
  name        = "relay"
  bucket_name = "relay-sessions"
  package     = { s3_bucket = "relay-artifacts", s3_key = "session-pipeline.zip" }
}

run "hosted_pattern_defaults" {
  command = apply

  assert {
    condition     = aws_sqs_queue.events.visibility_timeout_seconds == 6 * aws_lambda_function.this.timeout + aws_lambda_event_source_mapping.events.maximum_batching_window_in_seconds
    error_message = "Visibility timeout is six times the function timeout plus the batching window."
  }
  assert {
    condition     = jsondecode(aws_sqs_queue.events.redrive_policy).maxReceiveCount == 8
    error_message = "Messages move to the DLQ after 8 receives."
  }
  assert {
    condition     = aws_sqs_queue.dlq.message_retention_seconds == 1209600
    error_message = "The DLQ keeps messages 14 days."
  }
  assert {
    condition     = aws_sqs_queue.events.sqs_managed_sse_enabled && aws_sqs_queue.dlq.sqs_managed_sse_enabled
    error_message = "Queues are encrypted."
  }
  assert {
    condition     = aws_lambda_event_source_mapping.events.batch_size == 10 && contains(aws_lambda_event_source_mapping.events.function_response_types, "ReportBatchItemFailures")
    error_message = "Batch 10 with partial batch failures."
  }
  assert {
    condition     = one(aws_s3_bucket_notification.manifests[0].queue).filter_suffix == "/manifest.json" && one(aws_s3_bucket_notification.manifests[0].queue).filter_prefix == "96bulls/"
    error_message = "Only manifest.json objects under 96bulls/ are notified."
  }
  assert {
    condition     = aws_cloudwatch_event_rule.brief.state == "DISABLED" && aws_cloudwatch_event_rule.reconcile.state == "ENABLED"
    error_message = "Reconcile on, briefs off by default."
  }
  assert {
    condition     = aws_lambda_function.this.environment[0].variables.PIPELINE_RECONCILE_LOOKBACK_MINUTES == "60" && aws_lambda_function.this.environment[0].variables.SEARCH_INDEX_ENABLED == "0"
    error_message = "Lookback is twice the reconcile cadence; search index off by default."
  }
  assert {
    condition     = alltrue([for p in [aws_lambda_permission.reconcile, aws_lambda_permission.brief] : p.principal == "events.amazonaws.com" && p.source_arn != null])
    error_message = "Only EventBridge rules (by ARN) may invoke the function; there is no Function URL."
  }
  assert {
    condition     = contains(flatten([for s in jsondecode(aws_iam_role_policy.this.policy).Statement : s.Resource if s.Sid == "ReadSessionObjects"]), "arn:aws:s3:::relay-sessions/96bulls/*/v1/*")
    error_message = "The role reads only session objects."
  }
  assert {
    condition     = length([for s in jsondecode(aws_iam_role_policy.this.policy).Statement : s if contains(flatten([s.Action]), "s3:PutObject") || contains(flatten([s.Action]), "s3:DeleteObject")]) == 0
    error_message = "The role never writes or deletes objects."
  }
  assert {
    condition     = length([for s in jsondecode(aws_iam_role_policy.this.policy).Statement : s if s.Sid == "VpcNetworkInterfaces"]) == 0
    error_message = "No ENI permissions outside a VPC."
  }
  assert {
    condition     = alltrue([for a in [aws_cloudwatch_metric_alarm.dlq_not_empty, aws_cloudwatch_metric_alarm.backlog_age, aws_cloudwatch_metric_alarm.errors] : a.actions_enabled == false])
    error_message = "Alarms exist with actions disabled when no alarm_actions are given."
  }
}

run "briefs_enabled" {
  command = plan

  variables {
    briefs_enabled = true
  }

  assert {
    condition     = aws_cloudwatch_event_rule.brief.state == "ENABLED"
    error_message = "briefs_enabled turns the brief schedule on."
  }
}

run "exactly_one_package" {
  command = plan

  variables {
    package = { s3_bucket = "relay-artifacts", s3_key = "x.zip", image_uri = "111111111111.dkr.ecr.us-west-2.amazonaws.com/p:1" }
  }

  expect_failures = [var.package]
}

run "vpc_needs_security_groups" {
  command = plan

  variables {
    vpc_subnet_ids = ["subnet-a"]
  }

  expect_failures = [aws_lambda_function.this]
}

run "bucket_key_encryption_context" {
  command = plan

  variables {
    bucket_kms_key_arn = "arn:aws:kms:us-west-2:111111111111:key/abc"
  }

  assert {
    condition     = contains(one([for s in jsondecode(aws_iam_role_policy.this.policy).Statement : s.Condition.StringLike["kms:EncryptionContext:aws:s3:arn"] if s.Sid == "DecryptSessionObjectsViaS3"]), "arn:aws:s3:::relay-sessions")
    error_message = "Decrypt must accept the bucket ARN context (S3 Bucket Keys)."
  }
}

run "image_must_be_digest_pinned" {
  command = plan

  variables {
    package = { image_uri = "111111111111.dkr.ecr.us-west-2.amazonaws.com/pipeline:latest" }
  }

  expect_failures = [var.package]
}
