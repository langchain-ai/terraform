variable "vpc_name" {
  type        = string
  description = "The name of the VPC"
  default     = "langsmith-vpc"
}

variable "cluster_name" {
  type        = string
  description = "The name of the cluster"
  default     = "langsmith-eks"
}

variable "cidr_block" {
  type        = string
  description = "The CIDR block for the VPC"
  default     = "10.0.0.0/16" # a /16 CIDR has 64K IP addresses
}

variable "private_subnets" {
  type        = list(string)
  description = "The private subnets for the VPC"
  default     = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24", "10.0.12.0/24", "10.0.13.0/24"]
}

variable "public_subnets" {
  type        = list(string)
  description = "The public subnets for the VPC"
  default     = ["10.0.4.0/24", "10.0.5.0/24", "10.0.6.0/24"]
}
