# Variables for Ingress Module

# The kubectl steps below fetch their own credentials rather than trusting the
# ambient kubeconfig, so they need to know which cluster they are managing.
variable "project_id" {
  description = "GCP project ID hosting the cluster. Used to fetch cluster credentials for the kubectl provisioners."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.project_id))
    error_message = "project_id must be a GCP project ID: 6 to 30 lowercase letters, digits, or hyphens, starting with a letter."
  }
}

variable "region" {
  description = "Region of the GKE cluster. Used to fetch cluster credentials for the kubectl provisioners."
  type        = string

  validation {
    condition     = can(regex("^[a-z]+-[a-z]+[0-9]+$", var.region))
    error_message = "region must be a GCP region, for example us-central1."
  }
}

variable "cluster_name" {
  description = "Name of the GKE cluster the ingress resources are applied to. Used to fetch cluster credentials for the kubectl provisioners."
  type        = string

  validation {
    condition     = can(regex("^[a-z]([a-z0-9-]{0,38}[a-z0-9])?$", var.cluster_name))
    error_message = "cluster_name must be a GKE cluster name: up to 40 lowercase letters, digits, or hyphens, starting with a letter and ending with a letter or digit."
  }
}

variable "ingress_type" {
  description = "Type of ingress to install: 'envoy' or 'gke' (implemented), 'istio' or 'other' (reserved for future implementation)"
  type        = string
  default     = "envoy"

  validation {
    condition     = contains(["envoy", "gke", "istio", "other"], var.ingress_type)
    error_message = "Ingress type must be 'envoy' or 'gke' (currently implemented), 'istio', or 'other' (reserved for future)."
  }
}

variable "gke_gateway_class" {
  description = "GatewayClass to use when ingress_type = \"gke\" — e.g. 'gke-l7-global-external-managed' (public) or 'gke-l7-rilb' (internal-only regional)."
  type        = string
  default     = "gke-l7-global-external-managed"
}

variable "langsmith_domain" {
  description = "Domain name for LangSmith"
  type        = string
}

variable "langsmith_namespace" {
  description = "Kubernetes namespace for LangSmith"
  type        = string
  default     = "langsmith"

  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$", var.langsmith_namespace))
    error_message = "langsmith_namespace must be a Kubernetes namespace name: up to 63 lowercase letters, digits, or hyphens, starting and ending with a letter or digit."
  }
}

variable "gateway_name" {
  description = "Name for the Gateway resource (Envoy Gateway)"
  type        = string
  default     = "langsmith-gateway"

  # The GKE Gateway static IP is named <gateway_name>-ip, and a Compute Engine
  # name has at most 63 characters.
  validation {
    condition     = can(regex("^[a-z]([a-z0-9-]{0,58}[a-z0-9])?$", var.gateway_name))
    error_message = "gateway_name must be up to 60 lowercase letters, digits, or hyphens, starting with a letter and ending with a letter or digit."
  }
}

variable "tls_certificate_source" {
  description = "TLS certificate source: 'none', 'google-managed', 'existing', 'cert-manager', or 'letsencrypt'"
  type        = string
  default     = "none"

  validation {
    condition     = contains(["none", "google-managed", "existing", "cert-manager", "letsencrypt"], var.tls_certificate_source)
    error_message = "tls_certificate_source must be one of: none, google-managed, existing, cert-manager, letsencrypt."
  }
}

variable "tls_secret_name" {
  description = "Name of the TLS Secret, in the LangSmith namespace, for the Gateway HTTPS listener. Not used with 'none' or 'google-managed'."
  type        = string
  default     = "langsmith-tls"
}

variable "tls_certificate_map_name" {
  description = "Certificate Manager certificate map for the GKE Gateway, with tls_certificate_source = 'google-managed'."
  type        = string
  default     = ""
}

variable "gateway_api_crds_url" {
  description = "Gateway API CRD bundle that Envoy Gateway needs. k8s-bootstrap applies the same file ahead of cert-manager when Let's Encrypt is on, so the root passes one URL to both."
  type        = string
  default     = "https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.6.1/standard-install.yaml"

  validation {
    condition     = startswith(var.gateway_api_crds_url, "https://")
    error_message = "gateway_api_crds_url must be an https:// URL."
  }
}
