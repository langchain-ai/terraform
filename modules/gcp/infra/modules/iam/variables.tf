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

variable "workload_identity_service_accounts" {
  description = "Kubernetes service account names allowed to impersonate the LangSmith GCP service account via Workload Identity."
  type        = list(string)
  default = [
    "langsmith-ksa",
    "langsmith-backend",
    "langsmith-platform-backend",
    "langsmith-host-backend",
    "langsmith-queue",
    "langsmith-ingest-queue",
    "langsmith-listener",
    "langsmith-agent-builder-tool-server",
    "langsmith-agent-builder-trigger-server",
    "langsmith-ace-backend",
    "langsmith-frontend",
    "langsmith-playground",
    "langsmith-operator",
  ]
}

variable "gcs_bucket_name" {
  description = "Name of the GCS bucket for LangSmith blob storage"
  type        = string
}
