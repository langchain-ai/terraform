variable "cluster_name" {
  type        = string
  description = "Name of the EKS cluster"
}

variable "cluster_endpoint" {
  type        = string
  description = "EKS cluster API server endpoint"
}

variable "cluster_ca_certificate" {
  type        = string
  description = "Base64-encoded certificate authority data for the EKS cluster"
}

variable "region" {
  type        = string
  description = "AWS region"
}

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
