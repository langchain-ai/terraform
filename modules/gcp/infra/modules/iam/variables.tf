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

variable "namespace" {
  description = "Kubernetes namespace where LangSmith runs"
  type        = string
  default     = "langsmith"
}

variable "service_account_name" {
  description = "Kubernetes service account name for LangSmith"
  type        = string
  default     = "langsmith"
}

variable "gcs_bucket_name" {
  description = "Name of the GCS bucket for LangSmith blob storage"
  type        = string
}
