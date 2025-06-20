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
  default     = ["10.0.0.0/21", "10.0.8.0/21", "10.0.16.0/21", "10.0.24.0/21", "10.0.32.0/21"]
}

variable "public_subnets" {
  type        = list(string)
  description = "The public subnets for the VPC"
  default     = ["10.0.40.0/21", "10.0.48.0/21", "10.0.56.0/21"]
}

variable "extra_public_subnet_tags" {
  type        = map(string)
  description = "The tags for the public subnets"
  default = {
    "kubernetes.io/role/elb" = 1
  }
}

variable "extra_private_subnet_tags" {
  type        = map(string)
  description = "The tags for the private subnets"
  default = {
    "kubernetes.io/role/internal-elb" = 1
  }
}
