# Variables for IAM Module

variable "project_id" {
  description = "GCP Project ID"
  type        = string
}

variable "environment" {
  description = "Environment name"
  type        = string
}

#------------------------------------------------------------------------------
# Resource Names
#------------------------------------------------------------------------------
variable "service_account_id" {
  description = "Service account ID (short name)"
  type        = string
}

variable "service_account_name" {
  description = "Service account display name"
  type        = string
}

#------------------------------------------------------------------------------
# Workload Identity Configuration
#------------------------------------------------------------------------------
variable "gke_namespace" {
  description = "Kubernetes namespace for LangSmith"
  type        = string
  default     = "langsmith"
}

variable "workload_identity_pool" {
  description = "Workload Identity pool (usually PROJECT_ID.svc.id.goog)"
  type        = string
}
