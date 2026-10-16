variable "regions" {
  description = "AWS regions in this account in which the shared roles may operate LangSmith data planes."
  type        = set(string)

  validation {
    condition     = length(var.regions) > 0 && alltrue([for region in var.regions : can(regex("^[a-z]{2}(-[a-z]+)+-[0-9]+$", region))])
    error_message = "Provide at least one explicit AWS region; wildcards are not allowed."
  }
}

variable "permissions_boundary_arn" {
  description = "Optional customer IAM permissions boundary applied to all 16 application/infrastructure roles (not AWS service-linked roles)."
  type        = string
  default     = null

  validation {
    condition     = var.permissions_boundary_arn == null ? true : can(regex("^arn:aws[a-z-]*:iam::[0-9]{12}:policy/[a-zA-Z0-9/+=,.@_-]+$", var.permissions_boundary_arn))
    error_message = "Supply an IAM policy ARN without wildcards."
  }
}

variable "service_linked_roles_to_create" {
  description = "AWS service names whose account-level service-linked roles Terraform should create. Leave existing roles out or import them first; see README."
  type        = set(string)
  default     = []

  validation {
    condition = alltrue([for service in var.service_linked_roles_to_create : contains([
      "eks.amazonaws.com", "eks-nodegroup.amazonaws.com", "elasticloadbalancing.amazonaws.com",
      "rds.amazonaws.com", "elasticache.amazonaws.com", "autoscaling.amazonaws.com", "spot.amazonaws.com"
    ], service)])
    error_message = "Select only the documented EKS, ELB, RDS, ElastiCache, Auto Scaling, or Spot service-linked roles."
  }
}

variable "tags" {
  description = "Customer tags for IAM resources. Required IAM ownership tags cannot be overridden."
  type        = map(string)
  default     = {}

  validation {
    condition     = !contains(keys(var.tags), "managed_by")
    error_message = "Do not label customer-owned IAM resources managed_by=langsmith; that tag authorizes provisioning-role mutations."
  }
}

variable "smithdb_migration_writer_principal_arns" {
  description = "IAM role or user ARNs of self-hosted LangSmith installations that may assume the SmithDB role to write SmithDB data and the metastore during a migration. Set to [] after the migration."
  type        = list(string)
  default     = []

  validation {
    condition     = length(var.smithdb_migration_writer_principal_arns) <= 5 && alltrue([for arn in var.smithdb_migration_writer_principal_arns : can(regex("^arn:aws:iam::[0-9]{12}:(role|user)/[A-Za-z0-9+=,.@_/-]{1,512}$", arn))])
    error_message = "Provide at most five IAM role or user ARNs."
  }
}

variable "workload_migration_source_blob_bucket_arns" {
  description = "S3 bucket ARNs of self-hosted LangSmith installations whose run attachments migrate to this data plane. The workload role may read them so the attachment copy job can bring the attachments into the blob bucket. Set to [] after the migration."
  type        = list(string)
  default     = []

  validation {
    condition     = length(var.workload_migration_source_blob_bucket_arns) <= 5 && alltrue([for arn in var.workload_migration_source_blob_bucket_arns : can(regex("^arn:aws[a-z-]*:s3:::[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", arn))])
    error_message = "Provide at most five S3 bucket ARNs."
  }
}

variable "workload_migration_source_blob_kms_key_arns" {
  description = "KMS key ARNs that encrypt objects in workload_migration_source_blob_bucket_arns. The workload role may decrypt with them for objects in those buckets; the key owner must also authorize the role on each key. Set to [] after the migration."
  type        = list(string)
  default     = []

  validation {
    condition     = length(var.workload_migration_source_blob_kms_key_arns) <= 5 && alltrue([for arn in var.workload_migration_source_blob_kms_key_arns : can(regex("^arn:aws[a-z-]*:kms:[a-z0-9-]+:[0-9]{12}:key/([0-9a-f-]{36}|mrk-[0-9a-f]{32})$", arn))])
    error_message = "Provide at most five KMS key ARNs."
  }
}
