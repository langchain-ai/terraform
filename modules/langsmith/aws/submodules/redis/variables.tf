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
  default     = "cache.t3.medium"
}
