variable "namespace" {
  type        = string
  description = "Kubernetes namespace for LangSmith"
  default     = "langsmith"
}

variable "postgres_connection_url" {
  type        = string
  description = "PostgreSQL connection URL"
  sensitive   = true
}

variable "redis_connection_url" {
  type        = string
  description = "Redis connection URL"
  sensitive   = true
}

variable "tls_certificate_source" {
  type        = string
  description = "TLS source: 'acm', 'letsencrypt', or 'none'"
  default     = "acm"
}

variable "letsencrypt_email" {
  type        = string
  description = "Email for Let's Encrypt certificate registration. Required when tls_certificate_source = 'letsencrypt'."
  default     = ""
}

variable "eso_irsa_role_arn" {
  type        = string
  description = "ARN of the IRSA role for the External Secrets Operator controller"
}

variable "enable_envoy_gateway" {
  type        = bool
  description = "Install Envoy Gateway for Kubernetes Gateway API routing"
  default     = false
}
