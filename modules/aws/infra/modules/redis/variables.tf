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
