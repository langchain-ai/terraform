# Variables for Ingress Module

variable "ingress_type" {
  description = "Type of ingress to install: 'nginx' or 'envoy'"
  type        = string
  default     = "nginx"

  validation {
    condition     = contains(["nginx", "envoy"], var.ingress_type)
    error_message = "Ingress type must be 'nginx' or 'envoy'."
  }
}

variable "langsmith_domain" {
  description = "Domain name for LangSmith"
  type        = string
}

variable "langsmith_namespace" {
  description = "Kubernetes namespace for LangSmith"
  type        = string
  default     = "langsmith"
}

variable "gateway_name" {
  description = "Name for the Gateway resource (Envoy Gateway)"
  type        = string
  default     = "langsmith-gateway"
}
