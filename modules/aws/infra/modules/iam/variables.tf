variable "cluster_name" {
  description = "Name of the EKS cluster"
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

variable "project" {
  description = "Project name used for resource naming"
  type        = string
}

variable "environment" {
  description = "Deployment environment (dev, staging, prod)"
  type        = string
}

variable "blob_bucket_arn" {
  description = "ARN of the S3 bucket used for LangSmith blob storage"
  type        = string
}

variable "secrets_manager_secret_arn" {
  description = "ARN of the Secrets Manager secret containing LangSmith credentials"
  type        = string
}
