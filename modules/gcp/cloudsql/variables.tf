# Variables for Cloud SQL Module

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
# Resource Names
#------------------------------------------------------------------------------
variable "instance_name" {
  description = "Cloud SQL instance name"
  type        = string
}

variable "database_name" {
  description = "Database name"
  type        = string
  default     = "langsmith"
}

variable "username" {
  description = "Database username"
  type        = string
  default     = "langsmith"
}

#------------------------------------------------------------------------------
# Instance Configuration
#------------------------------------------------------------------------------
variable "database_version" {
  description = "PostgreSQL version"
  type        = string
  default     = "POSTGRES_18"
}

variable "tier" {
  description = "Cloud SQL instance tier"
  type        = string
  default     = "db-custom-2-8192"
}

variable "disk_size" {
  description = "Disk size in GB"
  type        = number
  default     = 50
}

#------------------------------------------------------------------------------
# Network Configuration
#------------------------------------------------------------------------------
variable "network_id" {
  description = "VPC network ID"
  type        = string
}

variable "use_private_ip" {
  description = "Use private IP for Cloud SQL (requires VPC peering). When false, uses public IP with SSL."
  type        = bool
  default     = true
}

variable "private_network_connection" {
  description = "Private service connection ID (required when use_private_ip = true)"
  type        = string
  default     = null
}

variable "authorized_networks" {
  description = "Authorized networks for public IP access (only used when use_private_ip = false)"
  type = list(object({
    name  = string
    value = string
  }))
  default = []
}

#------------------------------------------------------------------------------
# High Availability & Protection
#------------------------------------------------------------------------------
variable "high_availability" {
  description = "Enable high availability (regional)"
  type        = bool
  default     = true
}

variable "deletion_protection" {
  description = "Enable deletion protection"
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
