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
    large-node = {
      name           = "node-group-large-node"
      instance_types = ["m5.8xlarge"]
      min_size       = 1
      max_size       = 5
    }
  }
}

variable "redis_instance_type" {
  type        = string
  description = "Instance type for the redis cache"
  default     = "cache.m6g.xlarge"
}

variable "postgres_username" {
  type        = string
  description = "Username for the postgres database"
}

variable "postgres_password" {
  type        = string
  description = "Password for the postgres database"
}
