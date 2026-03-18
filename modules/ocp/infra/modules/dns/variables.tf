variable "namespace" {
  description = "Kubernetes namespace where LangSmith runs"
  type        = string
  default     = "langsmith"
}

variable "hostname" {
  description = "Hostname for the LangSmith Route (e.g. langsmith.apps.cluster.example.com)"
  type        = string
}

variable "tls_enabled" {
  description = "Whether to configure TLS on the Route"
  type        = bool
  default     = true
}

variable "cert_manager_issuer" {
  description = "Name of the cert-manager Issuer or ClusterIssuer to use for TLS (requires tls_enabled = true)"
  type        = string
  default     = "letsencrypt-prod"
}

variable "cert_manager_issuer_kind" {
  description = "Kind of the cert-manager issuer resource: Issuer or ClusterIssuer"
  type        = string
  default     = "ClusterIssuer"
}
