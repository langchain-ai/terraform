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

# ── KEDA ──────────────────────────────────────────────────────────────────────

variable "keda_version" {
  type        = string
  description = "KEDA Helm chart version"
  default     = "2.14.0"
}
