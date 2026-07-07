# smithdb: cloud dependencies for the in-chart SmithDB component of self-hosted
# LangSmith (chart 0.16+). Provisions the dedicated metastore Postgres, the
# object-store S3 bucket, and the IRSA role the SmithDB pods use for S3 access.
# The Kubernetes secrets and node groups that consume these are wired in the
# infra root; the Helm release itself is deployed in Pass 2 (helm/ or app/).

variable "name" {
  type        = string
  description = "Base name for SmithDB resources, e.g. {name_prefix}-{environment}-smithdb."
}

variable "region" {
  type        = string
  description = "AWS region. Used for the object-store bucket region in Helm values."
}

variable "tags" {
  type        = map(string)
  description = "Tags applied to all SmithDB resources."
  default     = {}
}

#------------------------------------------------------------------------------
# Networking / EKS references
#------------------------------------------------------------------------------
variable "vpc_id" {
  type        = string
  description = "VPC ID the EKS cluster runs in."
}

variable "private_subnet_ids" {
  type        = list(string)
  description = "Private subnet IDs (>= 2 distinct AZs) for the metastore RDS subnet group."
}

variable "eks_node_security_group_id" {
  type        = string
  description = "EKS node security group ID. The metastore SG allows 5432 ingress only from this SG."
}

variable "eks_oidc_provider_arn" {
  type        = string
  description = "EKS OIDC provider ARN. Used for the SmithDB IRSA trust policy."
}

variable "eks_oidc_provider_url" {
  type        = string
  description = "EKS OIDC provider URL (issuer without https://). Used for the SmithDB IRSA trust policy."
}

variable "namespace" {
  type        = string
  description = "Kubernetes namespace LangSmith/SmithDB run in. Scopes the IRSA trust policy."
}

variable "release_name" {
  type        = string
  description = "Helm release name. The SmithDB service account is <release_name>-langsmith-smithdb."
  default     = "langsmith"
}

#------------------------------------------------------------------------------
# Metastore (RDS Postgres) — dedicated instance per SmithDB Customer Engineering
# docs. Set metastore_source = external to bring your own Postgres.
#------------------------------------------------------------------------------
variable "metastore_source" {
  type        = string
  description = "SmithDB metastore Postgres: 'create' (dedicated RDS instance, default) or 'external' (bring-your-own)."
  default     = "create"

  validation {
    condition     = contains(["create", "external"], var.metastore_source)
    error_message = "metastore_source must be 'create' or 'external'."
  }
}

variable "metastore_instance_class" {
  type        = string
  description = "RDS instance class for the SmithDB metastore."
  default     = "db.m6g.large"
}

variable "metastore_engine_version" {
  type        = string
  description = "PostgreSQL engine version for the SmithDB metastore."
  default     = "16"
}

variable "metastore_allocated_storage" {
  type        = number
  description = "Allocated storage (GB) for the SmithDB metastore."
  default     = 50
}

variable "metastore_multi_az" {
  type        = bool
  description = "Run the SmithDB metastore RDS instance Multi-AZ."
  default     = false
}

variable "metastore_deletion_protection" {
  type        = bool
  description = "Prevent accidental deletion of the SmithDB metastore RDS instance."
  default     = true
}

variable "metastore_backup_retention_period" {
  type        = number
  description = "Days to retain automated backups of the SmithDB metastore. 0 disables backups."
  default     = 7
}

variable "metastore_skip_final_snapshot" {
  type        = bool
  description = "Skip the final snapshot when the SmithDB metastore RDS instance is destroyed. Set false for production."
  default     = true
}

variable "metastore_master_username" {
  type        = string
  description = "Master username for the SmithDB metastore RDS instance."
  default     = "smithdb"
}

variable "metastore_master_password" {
  type        = string
  description = "Master password for the SmithDB metastore. Leave null to auto-generate (metastore_source = create)."
  default     = null
  sensitive   = true
}

# External metastore fields (used when metastore_source = external).
variable "external_metastore_host" {
  type        = string
  description = "Hostname of an existing Postgres instance for the SmithDB metastore."
  default     = null
}

variable "external_metastore_port" {
  type        = number
  description = "Port of the existing SmithDB metastore Postgres instance."
  default     = 5432
}

variable "external_metastore_database" {
  type        = string
  description = "Database name on the existing SmithDB metastore Postgres instance."
  default     = "smithdb"
}

variable "external_metastore_username" {
  type        = string
  description = "Username for the existing SmithDB metastore Postgres instance."
  default     = null
}

variable "external_metastore_password" {
  type        = string
  description = "Password for the existing SmithDB metastore Postgres instance."
  default     = null
  sensitive   = true
}

#------------------------------------------------------------------------------
# Object store (S3)
#------------------------------------------------------------------------------
variable "bucket_name" {
  type        = string
  description = "Name of the SmithDB object-store bucket. Must be globally unique."
}

variable "s3_kms_key_arn" {
  type        = string
  description = "ARN of a KMS CMK for the object-store bucket. Empty uses SSE-S3 (AES256)."
  default     = ""
}

variable "s3_versioning_enabled" {
  type        = bool
  description = "Enable versioning on the SmithDB object-store bucket."
  default     = false
}

variable "s3_force_destroy" {
  type        = bool
  description = "Allow Terraform to delete a non-empty object-store bucket on destroy. Set true only for test stacks."
  default     = false
}

#------------------------------------------------------------------------------
# IRSA
#------------------------------------------------------------------------------
variable "service_account_role_arn" {
  type        = string
  description = "Existing IAM role ARN for the SmithDB service account. Leave null to have this module create one."
  default     = null
}
