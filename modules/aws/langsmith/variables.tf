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

variable "postgres_username" {
  type        = string
  description = "Username for the postgres database"
  default = "joaquin"
}

variable "postgres_password" {
  type        = string
  description = "Password for the postgres database"
  default = "joaquin123"
}
