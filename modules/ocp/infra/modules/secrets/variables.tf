variable "namespace" {
  description = "Kubernetes namespace where LangSmith runs"
  type        = string
  default     = "langsmith"
}

variable "postgres_password" {
  description = "PostgreSQL password"
  type        = string
  sensitive   = true
}

variable "redis_password" {
  description = "Redis password (leave empty if auth is disabled)"
  type        = string
  sensitive   = true
  default     = ""
}
