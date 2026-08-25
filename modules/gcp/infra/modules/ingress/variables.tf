# Variables for Ingress Module

# The kubectl steps below fetch their own credentials rather than trusting the
# ambient kubeconfig, so they need to know which cluster they are managing.
variable "project_id" {
  description = "GCP project ID hosting the cluster. Used to fetch cluster credentials for the kubectl provisioners."
  type        = string
}

variable "region" {
  description = "Region of the GKE cluster. Used to fetch cluster credentials for the kubectl provisioners."
  type        = string
}

variable "cluster_name" {
  description = "Name of the GKE cluster the ingress resources are applied to. Used to fetch cluster credentials for the kubectl provisioners."
  type        = string
}

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
