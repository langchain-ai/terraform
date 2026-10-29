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
# Sandbox Cluster Subnet (sandbox_runtime_source = "external")
#------------------------------------------------------------------------------
variable "create_sandbox_subnet" {
  description = "Create a second subnet, with its own pods and services ranges, for the dedicated sandbox GKE cluster."
  type        = bool
  default     = false
}

variable "sandbox_subnet_cidr" {
  description = "Primary CIDR range of the sandbox subnet (sandbox node IPs)"
  type        = string
  default     = "10.10.0.0/20"
}

variable "sandbox_pods_cidr" {
  description = "Secondary CIDR range for the sandbox cluster's pods"
  type        = string
  default     = "10.12.0.0/16"
}

variable "sandbox_services_cidr" {
  description = "Secondary CIDR range for the sandbox cluster's services"
  type        = string
  default     = "10.10.16.0/20"
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
