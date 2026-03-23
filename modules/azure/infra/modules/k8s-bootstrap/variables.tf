# ── Cluster connection ────────────────────────────────────────────────────────

variable "host" {
  type        = string
  description = "Kubernetes API server endpoint"
  sensitive   = true
}

variable "client_certificate" {
  type        = string
  description = "Base64-encoded client certificate from AKS kube_config"
  sensitive   = true
}

variable "client_key" {
  type        = string
  description = "Base64-encoded client key from AKS kube_config"
  sensitive   = true
}

variable "cluster_ca_certificate" {
  type        = string
  description = "Base64-encoded cluster CA certificate from AKS kube_config"
  sensitive   = true
}

# ── Namespace ─────────────────────────────────────────────────────────────────

variable "langsmith_namespace" {
  type        = string
  description = "Kubernetes namespace for LangSmith workloads"
  default     = "langsmith"
}

# ── Backing services ──────────────────────────────────────────────────────────

variable "use_external_postgres" {
  type        = bool
  description = "Create a Kubernetes secret for the external PostgreSQL connection URL"
  default     = true
}

variable "postgres_connection_url" {
  type        = string
  description = "PostgreSQL connection URL (postgresql://user:pass@host:5432/db?sslmode=require). Required when use_external_postgres = true"
  sensitive   = true
  default     = ""
}

variable "use_external_redis" {
  type        = bool
  description = "Create a Kubernetes secret for the external Redis connection URL"
  default     = true
}

variable "redis_connection_url" {
  type        = string
  description = "Redis connection URL (rediss://:key@host:6380). Required when use_external_redis = true"
  sensitive   = true
  default     = ""
}

# ── Blob storage (Azure Workload Identity) ────────────────────────────────────

variable "blob_managed_identity_client_id" {
  type        = string
  description = "Client ID of the User-Assigned Managed Identity used by LangSmith pods to access blob storage (Workload Identity)"
}

# ── Application secrets ───────────────────────────────────────────────────────
# License key is stored in K8s as langsmith-license secret.
# Other app secrets (api_key_salt, jwt_secret, admin_password) are written by
# helm/scripts/generate-secrets.sh from Azure Key Vault.

variable "langsmith_license_key" {
  type        = string
  description = "LangSmith enterprise license key (stored as K8s secret langsmith-license)"
  sensitive   = true
  default     = ""
}

# ── cert-manager ──────────────────────────────────────────────────────────────

variable "cert_manager_version" {
  type        = string
  description = "cert-manager Helm chart version"
  default     = "v1.14.4"
}

variable "tls_certificate_source" {
  type        = string
  description = "TLS certificate source. 'letsencrypt' = HTTP-01 via cert-manager (ClusterIssuer created by apply-cluster-issuers.sh). 'dns01' = DNS-01 via Azure DNS + Workload Identity (ClusterIssuer created by Terraform). 'none' = skip."
  default     = "letsencrypt"

  validation {
    condition     = contains(["letsencrypt", "dns01", "none"], var.tls_certificate_source)
    error_message = "tls_certificate_source must be 'letsencrypt', 'dns01', or 'none'."
  }
}

variable "letsencrypt_email" {
  type        = string
  description = "Email for Let's Encrypt certificate notifications. Required when tls_certificate_source = 'dns01'."
  default     = ""
}

variable "cert_manager_identity_client_id" {
  type        = string
  description = "Client ID of the cert-manager Managed Identity. Required when tls_certificate_source = 'dns01'."
  default     = ""
}

variable "dns_zone_name" {
  type        = string
  description = "Azure DNS zone name (e.g. langsmith.mycompany.com). Required when tls_certificate_source = 'dns01'."
  default     = ""
}

variable "dns_resource_group_name" {
  type        = string
  description = "Resource group containing the Azure DNS zone. Required when tls_certificate_source = 'dns01'."
  default     = ""
}

variable "subscription_id" {
  type        = string
  description = "Azure subscription ID. Required when tls_certificate_source = 'dns01' for the ClusterIssuer azureDNS config."
  default     = ""
}

# ── KEDA ──────────────────────────────────────────────────────────────────────

variable "keda_version" {
  type        = string
  description = "KEDA Helm chart version"
  default     = "2.14.0"
}
