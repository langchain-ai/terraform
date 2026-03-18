variable "identifier" {
  type        = string
  description = "Identifier for the database and related resources"
}

variable "db_name" {
  type        = string
  description = "Name of the database"
  default     = "postgres"
}

variable "instance_type" {
  type        = string
  description = "Instance type"
  default     = "db.t3.large" # 2 vCPU and 8 GB of memory
}

variable "storage_gb" {
  type        = number
  description = "Storage size in GB"
  default     = 10
}

variable "max_storage_gb" {
  type        = number
  description = "Maximum storage size in GB"
  default     = 100
}

variable "engine_version" {
  type        = string
  description = "Engine version"
  default     = "14"
}

variable "vpc_id" {
  type        = string
  description = "VPC ID"
}

variable "subnet_ids" {
  type        = list(string)
  description = "Subnet IDs"
}

variable "ingress_cidrs" {
  type        = list(string)
  description = "Ingress CIDR blocks"
}

variable "username" {
  type        = string
  description = "Username for the database"
}

variable "password" {
  type        = string
  description = "Password for the database"

  validation {
    condition     = can(regex("^[^/@\"' ]+$", var.password))
    error_message = "RDS master password must not contain '/', '@', '\"', single quotes, or spaces. Only printable ASCII characters excluding these are allowed."
  }
}

variable "iam_database_authentication_enabled" {
  type        = bool
  description = "Whether to enable IAM database authentication"
  default     = true
}

variable "iam_database_user" {
  type        = string
  description = "Database username for IAM authentication. This user must be created in PostgreSQL with 'GRANT rds_iam TO <user>'"
  default     = null
}

variable "iam_auth_role_name" {
  type        = string
  description = "Name of the IAM role to attach the RDS IAM auth policy to (e.g., IRSA role for K8s pods)"
  default     = null
}

variable "vpc_cidr_block" {
  type        = string
  description = "VPC CIDR block. Used to scope security group egress rules to within the VPC."
}

variable "backup_retention_period" {
  type        = number
  description = "Number of days to retain automated RDS backups. 0 disables backups entirely."
  default     = 7
}

variable "deletion_protection" {
  type        = bool
  description = "Prevent accidental RDS instance deletion. Set false for dev/test environments where you need to destroy and recreate."
  default     = true
}
