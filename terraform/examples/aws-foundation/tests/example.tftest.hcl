mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = { account_id = "111111111111", arn = "arn:aws:iam::111111111111:role/example-operator" }
  }
  mock_data "aws_region" { defaults = { region = "us-west-2" } }
  mock_resource "aws_eks_cluster" {
    defaults = { arn = "arn:aws:eks:us-west-2:111111111111:cluster/example" }
  }
  mock_resource "aws_cloudwatch_log_group" { defaults = { arn = "arn:aws:logs:us-west-2:111111111111:log-group:example" } }
  mock_resource "aws_launch_template" { defaults = { id = "lt-0123456789abcdef0", latest_version = 1 } }
  mock_resource "aws_iam_role" { defaults = { arn = "arn:aws:iam::111111111111:role/example" } }
}
variables {
  account_id               = "111111111111"
  region                   = "us-west-2"
  environment              = "dev"
  kubernetes_version       = "1.35"
  node_ami_release_version = "1.35.0-20260101"
  addon_versions = {
    vpc-cni                = "v1.21.0-eksbuild.1"
    kube-proxy             = "v1.35.0-eksbuild.1"
    coredns                = "v1.12.0-eksbuild.1"
    eks-pod-identity-agent = "v1.3.0-eksbuild.1"
    aws-ebs-csi-driver     = "v1.40.0-eksbuild.1"
  }
  subnets = {
    us-west-2a = { public_cidr = "10.80.0.0/24", private_cidr = "10.80.16.0/20" }
    us-west-2b = { public_cidr = "10.80.1.0/24", private_cidr = "10.80.32.0/20" }
  }
  actor_availability_zone = "us-west-2a"
  operator_cidrs          = ["192.0.2.0/24"]
  operator_role_arns      = ["arn:aws:iam::111111111111:role/example-operator"]
  kms_key_arn             = "arn:aws:kms:us-west-2:111111111111:key/00000000-0000-0000-0000-000000000000"
}
run "root_output_contract" {
  command = apply
  assert {
    condition     = output.data_environment_inputs.name_prefix == var.name_prefix && output.data_environment_inputs.release_name == var.release_name && output.data_environment_inputs.account_id == var.account_id && output.data_environment_inputs.environment == var.environment && length(output.data_environment_inputs.private_subnet_ids) == 2 && length(output.data_environment_inputs.function_security_group_ids) == 1 && output.identity_references.namespace == output.data_environment_inputs.namespace
    error_message = "Root outputs must feed the separate data environment without credentials."
  }
}
