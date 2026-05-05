# Variables for Networking Module

variable "project_id" {
  description = "GCP Project ID"
  type        = string
}

variable "region" {
  description = "GCP region"
  type        = string
}

variable "environment" {
  description = "Environment name"
  type        = string
}

#------------------------------------------------------------------------------
# Resource Names (passed from root module for consistency)
#------------------------------------------------------------------------------
variable "vpc_name" {
  description = "Name of the VPC network"
  type        = string
}

variable "subnet_name" {
  description = "Name of the subnet"
  type        = string
  default     = ""
}

variable "router_name" {
  description = "Name of the Cloud Router"
  type        = string
  default     = ""
}

variable "nat_name" {
  description = "Name of the Cloud NAT"
  type        = string
  default     = ""
}

#------------------------------------------------------------------------------
# Network Configuration
#------------------------------------------------------------------------------
variable "subnet_cidr" {
  description = "CIDR range for the subnet"
  type        = string
}

variable "pods_cidr" {
  description = "CIDR range for GKE pods"
  type        = string
}

variable "services_cidr" {
  description = "CIDR range for GKE services"
  type        = string
}

#------------------------------------------------------------------------------
# Private Service Connection
#------------------------------------------------------------------------------
variable "enable_private_service_connection" {
  description = "Enable VPC peering for private service access (Cloud SQL, Redis). Requires servicenetworking.networksAdmin role."
  type        = bool
  default     = true
}

#------------------------------------------------------------------------------
# Labels
#------------------------------------------------------------------------------
variable "labels" {
  description = "Labels to apply to resources"
  type        = map(string)
  default     = {}
}
