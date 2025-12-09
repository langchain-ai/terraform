variable "identifier" {
  type        = string
  description = "Identifier for the LangSmith resources. Example: '-prod' or '-staging'"
  default     = ""
}

variable "region" {
  type        = string
  description = "AWS region for all resources"
  default     = "us-west-2"
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
}

variable "enable_public_eks_cluster" {
  type        = bool
  description = "Whether to enable public access to the EKS cluster."
  default     = true
}

variable "eks_cluster_version" {
  type        = string
  description = "The EKS version of the kubernetes cluster"
  default     = "1.31"
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

variable "eks_managed_node_groups" {
  type        = map(any)
  description = "EKS managed node groups"
  default = {
    default = {
      name           = "node-group-default"
      instance_types = ["m5.4xlarge"]
      min_size       = 1
      max_size       = 10
    }
  }
}

variable "redis_instance_type" {
  type        = string
  description = "Instance type for the redis cache"
  default     = "cache.m6g.xlarge"
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
}

variable "postgres_max_storage_gb" {
  type        = number
  description = "Maximum storage size in GB for the postgres database. This is used to enable volume expansion."
  default     = 100
}

variable "postgres_username" {
  type        = string
  description = "Username for the postgres database"
}

variable "postgres_password" {
  type        = string
  description = "Password for the postgres database"
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

# IRSA (IAM Roles for Service Accounts) settings
variable "create_langsmith_irsa_role" {
  type        = bool
  description = "Whether to create an IRSA role for LangSmith pods"
  default     = true
}
