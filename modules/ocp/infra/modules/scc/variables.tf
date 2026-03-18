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
