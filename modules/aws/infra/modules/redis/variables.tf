variable "name" {
  description = "The name of the redis instance"
  type        = string
}

variable "vpc_id" {
  description = "The ID of the vpc to deploy the redis instance into"
  type        = string
}

variable "subnet_ids" {
  description = "The subnets of the vpc to deploy into"
  type        = list(string)
}

variable "ingress_cidrs" {
  description = "CIDR block to allow ingress from"
  type        = list(string)
}

variable "instance_type" {
  description = "The instance type of the redis instance"
  type        = string
  default     = "cache.m5.large" # 2 vCPU and 6 GB of memory
}

variable "vpc_cidr_block" {
  type        = string
  description = "VPC CIDR block. Used to scope security group egress rules to within the VPC."
}

variable "auth_token" {
  description = "Auth token for Redis in-transit encryption. Must be hex string (no base64 special chars)."
  type        = string
  sensitive   = true
}

variable "parameter_group_name" {
  description = "ElastiCache parameter group name."
  type        = string
  default     = "default.redis7"
}

variable "snapshot_retention_limit" {
  description = "Number of days to retain automated Redis snapshots. 0 disables automated snapshots."
  type        = number
  default     = 0
}
