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

variable "domain_name" {
  description = "Root domain name for LangSmith (e.g. langsmith.example.com)"
  type        = string
}

variable "create_zone" {
  description = "Whether to create a new Cloud DNS managed zone"
  type        = bool
  default     = true
}

variable "existing_zone_name" {
  description = "Name of an existing Cloud DNS managed zone (used when create_zone = false)"
  type        = string
  default     = ""
}

variable "create_certificate" {
  description = "Whether to create a Google-managed SSL certificate"
  type        = bool
  default     = true
}
