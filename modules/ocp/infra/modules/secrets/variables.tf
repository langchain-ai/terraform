variable "namespace" {
  description = "Kubernetes namespace where LangSmith runs"
  type        = string
  default     = "langsmith"
}

variable "postgres_connection_url" {
  description = "Full PostgreSQL connection URL (postgresql://user:password@host:5432/database). Leave empty to skip the secret — generate-secrets.sh or an external secrets operator then owns it."
  type        = string
  sensitive   = true
  default     = ""
}

variable "redis_connection_url" {
  description = "Full Redis connection URL (redis://:password@host:6379/0, or rediss:// for TLS). Leave empty to skip the secret."
  type        = string
  sensitive   = true
  default     = ""
}
