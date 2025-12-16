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

variable "password" {
  description = "PostgreSQL database password"
  type        = string
  sensitive   = true

  validation {
    condition     = length(var.password) >= 8
    error_message = "Password must be at least 8 characters long."
  }
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

variable "private_network_connection" {
  description = "Private service connection ID (required for Cloud SQL private IP)"
  type        = string
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
