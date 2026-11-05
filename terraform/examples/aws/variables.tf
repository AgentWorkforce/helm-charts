variable "region" {
  description = "AWS region."
  type        = string
}

variable "name" {
  description = "Name prefix for every resource (lowercase; at most 21 characters, so <name>-search fits OpenSearch's 28)."
  type        = string
  default     = "agent-relay"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,20}$", var.name))
    error_message = "name must be 1-21 lowercase letters, digits and hyphens, starting with a letter."
  }
}

variable "tags" {
  description = "Tags for every resource (provider default_tags)."
  type        = map(string)
  default     = {}
}

variable "kms_key_arn" {
  description = "Customer managed KMS key for every data store (null: AWS managed keys)."
  type        = string
  default     = null
}

# --- Bring your own network ---------------------------------------------------

variable "private_subnet_ids" {
  description = "Existing private subnets (two or more AZs) for the database and the function."
  type        = list(string)
}

variable "database_security_group_ids" {
  description = "Existing security groups for Postgres (5432 from the EKS nodes/pods)."
  type        = list(string)
}

variable "search_subnet_ids" {
  description = "Existing private subnets for OpenSearch (one per AZ, 2 or 3)."
  type        = list(string)
  default     = []
}

variable "search_security_group_ids" {
  description = "Existing security groups for OpenSearch (443 from the indexer and read API)."
  type        = list(string)
  default     = []
}

variable "function_security_group_ids" {
  description = "Existing security groups for the pipeline function ENIs."
  type        = list(string)
  default     = []
}

# --- Cluster and release ------------------------------------------------------

variable "eks_cluster_name" {
  description = "Existing EKS cluster that runs agent-relay (Pod Identity associations)."
  type        = string
}

variable "namespace" {
  description = "agent-relay release namespace."
  type        = string
  default     = "agent-relay"
}

variable "release_name" {
  description = "agent-relay Helm release name."
  type        = string
  default     = "agent-relay"
}

# --- Components ---------------------------------------------------------------

variable "postgres_engine_mode" {
  description = "rds or aurora."
  type        = string
  default     = "rds"
}

variable "aurora_engine_version" {
  description = "Aurora PostgreSQL version when postgres_engine_mode is aurora."
  type        = string
  default     = "17.9"
}

variable "sessions_bucket_name" {
  description = "Globally unique S3 bucket name for session objects."
  type        = string
}

variable "enable_search" {
  description = "Create the optional OpenSearch domain."
  type        = bool
  default     = false
}

variable "search_master_user_arn" {
  description = "IAM role that administers OpenSearch fine-grained access control."
  type        = string
  default     = null
}

variable "enable_functions" {
  description = "Create the optional event-driven pipeline (Lambda)."
  type        = bool
  default     = false
}

variable "pipeline_package" {
  description = "Pipeline Lambda package (see modules/aws/functions)."
  type = object({
    image_uri         = optional(string)
    s3_bucket         = optional(string)
    s3_key            = optional(string)
    s3_object_version = optional(string)
    filename          = optional(string)
    source_code_hash  = optional(string)
  })
  # Empty: with enable_functions the module refuses it until one source is set.
  default = {}
}

variable "alarm_actions" {
  description = "SNS topics for the pipeline alarms."
  type        = list(string)
  default     = []
}
