# Variables for Ingress Module

variable "ingress_type" {
  description = "Type of ingress to install: 'envoy' (implemented), 'istio' or 'other' (reserved for future implementation)"
  type        = string
  default     = "envoy"

  validation {
    condition     = contains(["envoy", "istio", "other"], var.ingress_type)
    error_message = "Ingress type must be 'envoy' (currently implemented), 'istio', or 'other' (reserved for future)."
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

variable "tls_certificate_source" {
  description = "TLS certificate source: 'none', 'letsencrypt', or 'existing'"
  type        = string
  default     = "none"
}

variable "tls_secret_name" {
  description = "Name of the TLS secret for Gateway HTTPS listener"
  type        = string
  default     = "langsmith-tls"
}
