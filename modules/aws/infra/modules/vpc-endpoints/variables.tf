variable "name" {
  type        = string
  description = "Name prefix for the endpoints and their security group"
}

variable "region" {
  type        = string
  description = "AWS region the endpoint service names are built for"
}

variable "vpc_id" {
  type        = string
  description = "VPC the endpoints are created in"
}

variable "subnet_ids" {
  type        = list(string)
  description = "Subnets for the endpoint network interfaces, at most one per AZ"
}

variable "ingress_cidrs" {
  type        = list(string)
  description = "CIDRs allowed to reach the endpoints on 443"
}

variable "services" {
  type        = list(string)
  description = "Service suffixes after com.amazonaws.<region>., such as ecr.api"
}
