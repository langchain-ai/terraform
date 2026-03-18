variable "identifier" {
  type        = string
  description = "Identifier for the LangSmith resources. Example: '-prod' or '-staging'"
  default     = ""
}

variable "region" {
  type        = string
  description = "AWS region for all resources"
  default     = "us-west-2"

  validation {
    condition     = can(regex("^[a-z]+-[a-z]+-[0-9]$", var.region))
    error_message = "Region must be a valid AWS region (e.g., us-west-2, eu-west-1)."
  }
}

variable "create_vpc" {
  type        = bool
  description = "Whether to create a new VPC"
  default     = true
}

variable "vpc_id" {
  type        = string
  description = "ID of the VPC. Required if create_vpc is false."
  default     = null
}

variable "private_subnets" {
  type        = list(string)
  description = "Private subnets. Required if create_vpc is false."
  default     = []
}

variable "public_subnets" {
  type        = list(string)
  description = "Public subnets. Required if create_vpc is false."
  default     = []
}

variable "vpc_cidr_block" {
  type        = string
  description = "VPC CIDR block. Required if create_vpc is false."
  default     = null

  validation {
    condition     = var.vpc_cidr_block == null || can(cidrhost(var.vpc_cidr_block, 0))
    error_message = "VPC CIDR block must be a valid CIDR notation (e.g., 10.0.0.0/16)."
  }
}

variable "enable_public_eks_cluster" {
  type        = bool
  description = "Whether to enable public access to the EKS cluster API endpoint."
  default     = true
}

variable "eks_public_access_cidrs" {
  type        = list(string)
  description = "CIDRs allowed to reach the public EKS API endpoint. Defaults to unrestricted (0.0.0.0/0). Set to your corporate VPN egress CIDRs to lock down access while keeping the endpoint public."
  default     = ["0.0.0.0/0"]
}

variable "eks_cluster_version" {
  type        = string
  description = "The EKS version of the kubernetes cluster"
  default     = "1.31"

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+$", var.eks_cluster_version))
    error_message = "EKS cluster version must be in format X.Y (e.g., 1.31)."
  }
}

variable "eks_tags" {
  type        = map(string)
  description = "Tags to apply to the EKS cluster"
  default     = {}
}

variable "create_gp3_storage_class" {
  type        = bool
  description = "Whether to create the gp3 storage class. The gp3 storage class will be patched to make it default and allow volume expansion."
  default     = true
}

variable "eks_managed_node_group_defaults" {
  type        = any
  description = "Default configuration for EKS managed node groups"
  default = {
    ami_type = "AL2023_x86_64_STANDARD"
  }
}

variable "eks_managed_node_groups" {
  type        = map(any)
  description = "EKS managed node groups"
  default = {
    default = {
      name           = "node-group-default"
      instance_types = ["m5.4xlarge"]
      min_size       = 3
      max_size       = 10
    }
  }
}

#------------------------------------------------------------------------------
# PostgreSQL (RDS) Configuration
#------------------------------------------------------------------------------
variable "postgres_source" {
  type        = string
  description = "PostgreSQL deployment type: 'external' (default, RDS with private access) or 'in-cluster' (deployed via Helm)"
  default     = "external"

  validation {
    condition     = contains(["external", "in-cluster"], var.postgres_source)
    error_message = "postgres_source must be one of: external, in-cluster."
  }
}

variable "postgres_instance_type" {
  type        = string
  description = "Instance type for the postgres database"
  default     = "db.t3.large"
}

variable "postgres_storage_gb" {
  type        = number
  description = "Storage size in GB for the postgres database"
  default     = 10

  validation {
    condition     = var.postgres_storage_gb >= 5 && var.postgres_storage_gb <= 65536
    error_message = "Postgres storage must be between 5 and 65536 GB."
  }
}

variable "postgres_max_storage_gb" {
  type        = number
  description = "Maximum storage size in GB for the postgres database. This is used to enable volume expansion."
  default     = 100

  validation {
    condition     = var.postgres_max_storage_gb >= 5 && var.postgres_max_storage_gb <= 65536
    error_message = "Postgres max storage must be between 5 and 65536 GB."
  }
}

variable "postgres_username" {
  type        = string
  description = "Username for the postgres database. Required when postgres_source = 'external'."
  default     = "langsmith"
}

variable "postgres_password" {
  type        = string
  description = "Password for the postgres database. Required when postgres_source = 'external'. Use TF_VAR_postgres_password env var."
  default     = ""
  sensitive   = true
}

variable "postgres_iam_database_authentication_enabled" {
  type        = bool
  description = "Whether to enable IAM database authentication for the postgres database"
  default     = true
}

variable "postgres_iam_database_user" {
  type        = string
  description = "Database username for IAM authentication. This user must be created in PostgreSQL with 'GRANT rds_iam TO <user>'"
  default     = null
}

variable "postgres_deletion_protection" {
  type        = bool
  description = "Prevent accidental RDS instance deletion. Set false for dev/test environments where you need to destroy and recreate."
  default     = true
}

variable "postgres_backup_retention_period" {
  type        = number
  description = "Days to retain automated RDS backups. 7 is the recommended baseline. 0 disables backups entirely."
  default     = 7
}

#------------------------------------------------------------------------------
# Redis (ElastiCache) Configuration
#------------------------------------------------------------------------------
variable "redis_source" {
  type        = string
  description = "Redis deployment type: 'external' (default, ElastiCache with private access) or 'in-cluster' (deployed via Helm)"
  default     = "external"

  validation {
    condition     = contains(["external", "in-cluster"], var.redis_source)
    error_message = "redis_source must be one of: external, in-cluster."
  }
}

variable "redis_instance_type" {
  type        = string
  description = "Instance type for the redis cache. Required when redis_source = 'external'."
  default     = "cache.m6g.xlarge"
}

variable "redis_auth_token" {
  type        = string
  description = "Auth token for Redis. Auto-generated by setup-env.sh and stored in SSM. Required when redis_source = 'external'."
  default     = ""
  sensitive   = true
}

#------------------------------------------------------------------------------
# ALB Network Access
#------------------------------------------------------------------------------
variable "alb_internal" {
  type        = bool
  description = "If true, the ALB is internal (private subnets, no public access). If false, internet-facing (public subnets). You can start internal and switch to public later by setting this to false and re-applying."
  default     = false
}

variable "alb_allowed_cidr_blocks" {
  type        = list(string)
  description = "CIDR blocks allowed to reach the ALB on HTTP/HTTPS. Defaults to open. Restrict to VPN/office CIDRs for internal or limited-access deployments (e.g. [\"10.0.0.0/8\", \"172.16.0.0/12\"])."
  default     = ["0.0.0.0/0"]
}

#------------------------------------------------------------------------------
# ALB Access Logs
#------------------------------------------------------------------------------
variable "alb_access_logs_enabled" {
  type        = bool
  description = "Enable ALB access logging to a dedicated S3 bucket. Useful for traffic analysis and compliance."
  default     = false
}

#------------------------------------------------------------------------------
# CloudTrail
#------------------------------------------------------------------------------
variable "create_cloudtrail" {
  type        = bool
  description = "Create a CloudTrail trail logging all AWS API calls to S3. Skip if your organization already has an account-level or org-level trail."
  default     = false
}

variable "cloudtrail_multi_region" {
  type        = bool
  description = "Record API calls across all regions. Recommended — single-region trails miss global service events."
  default     = true
}

variable "cloudtrail_log_retention_days" {
  type        = number
  description = "Days to retain CloudTrail logs in S3. Set 0 to keep indefinitely."
  default     = 365
}

#------------------------------------------------------------------------------
# WAF
#------------------------------------------------------------------------------
variable "create_waf" {
  type        = bool
  description = "Attach a WAFv2 Web ACL to the ALB. Includes AWS managed rules for OWASP Top 10, IP reputation, and known bad inputs. Cost: ~$8-10/mo base."
  default     = false
}

#------------------------------------------------------------------------------
# Storage (S3) Configuration
#------------------------------------------------------------------------------
variable "s3_ttl_enabled" {
  type        = bool
  description = "Enable S3 lifecycle rules to automatically expire trace blobs. Mirrors Azure Blob TTL pattern."
  default     = true
}

variable "s3_ttl_short_days" {
  type        = number
  description = "Days before expiring short-lived trace objects (ttl_s/ prefix). Default: 14."
  default     = 14
}

variable "s3_ttl_long_days" {
  type        = number
  description = "Days before expiring long-lived trace objects (ttl_l/ prefix). Default: 400."
  default     = 400
}

variable "s3_kms_key_arn" {
  type        = string
  description = "ARN of a KMS CMK for S3 encryption. Upgrades from SSE-S3 (AES256) to SSE-KMS. Leave empty to use default SSE-S3."
  default     = ""
}

variable "s3_versioning_enabled" {
  type        = bool
  description = "Enable S3 bucket versioning. Increases storage costs as all prior object versions are retained."
  default     = false
}

# IRSA (IAM Roles for Service Accounts) settings
variable "create_langsmith_irsa_role" {
  type        = bool
  description = "Whether to create an IRSA role for LangSmith pods"
  default     = true
}

variable "eks_cluster_enabled_log_types" {
  type        = list(string)
  description = "EKS control plane log types to enable. Logs go to CloudWatch. Set to [] to disable."
  default     = ["api", "audit", "authenticator", "controllerManager", "scheduler"]
}

# EKS Blueprints Addons
variable "eks_addons" {
  type        = any
  description = "Map of EKS managed add-on configurations to enable for the cluster (coredns, kube-proxy, vpc-cni, etc.)"
  default     = {}
}

variable "name_prefix" {
  type        = string
  description = "Prefix for all resource names. Use your company/team name (max 11 chars). Format: {prefix}-{environment}-{resource}"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,10}$", var.name_prefix))
    error_message = "name_prefix must be 1-11 characters, start with a lowercase letter, and contain only lowercase letters, numbers, and hyphens."
  }
}

variable "environment" {
  type        = string
  description = "Deployment environment (dev, staging, prod, test, uat)"
  default     = "dev"

  validation {
    condition     = contains(["dev", "staging", "prod", "test", "uat"], var.environment)
    error_message = "Environment must be one of: dev, staging, prod, test, uat."
  }
}

variable "langsmith_namespace" {
  type        = string
  description = "Kubernetes namespace for LangSmith"
  default     = "langsmith"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,62}$", var.langsmith_namespace))
    error_message = "Namespace must be a valid Kubernetes namespace name (lowercase, alphanumeric, hyphens)."
  }
}

variable "tls_certificate_source" {
  type        = string
  description = "TLS certificate provider: 'acm' (AWS Certificate Manager, default), 'letsencrypt' (cert-manager), or 'none' (HTTP only)"
  default     = "acm"
  validation {
    condition     = contains(["acm", "letsencrypt", "none"], var.tls_certificate_source)
    error_message = "tls_certificate_source must be 'acm', 'letsencrypt', or 'none'."
  }
}

variable "acm_certificate_arn" {
  type        = string
  description = "ARN of an existing ACM certificate. Required when tls_certificate_source = 'acm'."
  default     = ""

  validation {
    condition     = var.acm_certificate_arn == "" || can(regex("^arn:aws:acm:[a-z0-9-]+:[0-9]{12}:certificate/[a-z0-9-]+$", var.acm_certificate_arn))
    error_message = "acm_certificate_arn must be a valid ACM certificate ARN (e.g., arn:aws:acm:us-west-2:123456789012:certificate/...)."
  }
}

variable "letsencrypt_email" {
  type        = string
  description = "Email for Let's Encrypt certificate registration. Required when tls_certificate_source = 'letsencrypt'."
  default     = ""
}

variable "langsmith_domain" {
  type        = string
  description = "Custom domain for LangSmith (e.g. langsmith.example.com). When set (and acm_certificate_arn is empty), activates the dns module to auto-provision a Route 53 hosted zone, ACM certificate, and alias record. Leave empty to skip DNS/ACM and access LangSmith via the ALB hostname directly."
  default     = ""
}

variable "owner" {
  type        = string
  description = "Team or individual responsible for this deployment. Applied as a tag to all resources."
  default     = ""
}

variable "cost_center" {
  type        = string
  description = "Cost center or billing label. Applied as a tag when non-empty."
  default     = ""
}

variable "tags" {
  type        = map(string)
  description = "Additional tags to apply to all resources."
  default     = {}
}

#------------------------------------------------------------------------------
# ClickHouse Configuration
#------------------------------------------------------------------------------
variable "clickhouse_source" {
  type        = string
  description = "ClickHouse deployment type. 'in-cluster' deploys ClickHouse as a pod via Helm (default). 'external' is reserved for self-hosted or LangChain-managed ClickHouse — configure via Helm values."
  default     = "in-cluster"

  validation {
    condition     = contains(["in-cluster", "external"], var.clickhouse_source)
    error_message = "clickhouse_source must be 'in-cluster' or 'external'."
  }
}

#------------------------------------------------------------------------------
# LangGraph Platform Encryption Keys
# Fernet keys for optional feature modules. Generate once and never change.
# Set via setup-env.sh (TF_VAR_*) — stored in SSM Parameter Store.
# Required only when enabling the corresponding feature overlay in Helm.
#------------------------------------------------------------------------------
variable "langsmith_deployments_encryption_key" {
  type        = string
  description = "Fernet key for LangSmith Deployments. Generate once: python -c 'from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())'. Store in SSM: /langsmith/{base_name}/deployments-encryption-key."
  sensitive   = true
  default     = ""
}

variable "langsmith_agent_builder_encryption_key" {
  type        = string
  description = "Fernet key for Agent Builder. Generate once and keep stable. Store in SSM: /langsmith/{base_name}/agent-builder-encryption-key."
  sensitive   = true
  default     = ""
}

variable "langsmith_insights_encryption_key" {
  type        = string
  description = "Fernet key for Insights. Generate once — changing breaks existing insights data. Store in SSM: /langsmith/{base_name}/insights-encryption-key."
  sensitive   = true
  default     = ""
}

variable "project" {
  type        = string
  description = "DEPRECATED: Use name_prefix instead. Retained for backwards compatibility."
  default     = ""
}
