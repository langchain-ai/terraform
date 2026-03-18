variable "project" {
  description = "Project name used for resource naming"
  type        = string
}

variable "environment" {
  description = "Deployment environment (dev, staging, prod)"
  type        = string
}

variable "recovery_window_in_days" {
  description = "Number of days before the secret is permanently deleted after being marked for deletion. Set to 0 for immediate deletion (required for test environments to avoid 'secret scheduled for deletion' errors on re-deploy)."
  type        = number
  default     = 0
}

variable "postgres_password" {
  description = "PostgreSQL password to store in Secrets Manager"
  type        = string
  sensitive   = true
}

variable "redis_auth_token" {
  description = "Redis auth token to store in Secrets Manager"
  type        = string
  sensitive   = true
}
