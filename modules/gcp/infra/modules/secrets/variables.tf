variable "gcp_project" {
  description = "GCP project ID"
  type        = string
}

variable "project" {
  description = "Project name used for resource naming"
  type        = string
}

variable "environment" {
  description = "Deployment environment (dev, staging, prod)"
  type        = string
}

variable "postgres_password" {
  description = "PostgreSQL password to store in Secret Manager"
  type        = string
  sensitive   = true
}

variable "redis_password" {
  description = "Redis password to store in Secret Manager (leave empty if auth is disabled)"
  type        = string
  sensitive   = true
  default     = ""
}
