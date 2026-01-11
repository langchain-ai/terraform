# Variables for Redis Module

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
  description = "Redis instance name"
  type        = string
}

#------------------------------------------------------------------------------
# Instance Configuration
#------------------------------------------------------------------------------
variable "memory_size_gb" {
  description = "Redis memory size in GB"
  type        = number
  default     = 5
}

variable "redis_version" {
  description = "Redis version"
  type        = string
  default     = "REDIS_7_2"
}

#------------------------------------------------------------------------------
# Network Configuration
#------------------------------------------------------------------------------
variable "network_id" {
  description = "VPC network ID"
  type        = string
}

#------------------------------------------------------------------------------
# High Availability
#------------------------------------------------------------------------------
variable "high_availability" {
  description = "Enable high availability (Standard HA tier)"
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
