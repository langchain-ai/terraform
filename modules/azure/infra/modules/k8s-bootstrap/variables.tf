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

variable "postgres_admin_password" {
  type        = string
  description = "PostgreSQL admin password. Added as POSTGRES_PASSWORD to the postgres secret for listener-managed agent deployments."
  sensitive   = true
  default     = ""
}

variable "enable_fleet" {
  type        = bool
  description = "Create the langsmith-fleet-postgres secret for standalone Fleet (chart v0.15+)."
  default     = false
}

variable "fleet_postgres_connection_url" {
  type        = string
  description = "Connection URL for the dedicated Fleet Postgres database (langsmith_fleet). Required when enable_fleet = true and use_external_postgres = true."
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
  description = "Redis connection URL (rediss://:key@host:10000). Required when use_external_redis = true"
  sensitive   = true
  default     = ""
}

variable "enable_smithdb" {
  type        = bool
  description = "Create the SmithDB PostgreSQL metastore connection Secret."
  default     = false
}

variable "smithdb_metastore_host" {
  type        = string
  description = "Private hostname of the SmithDB PostgreSQL metastore."
  default     = ""
}

variable "smithdb_metastore_database" {
  type        = string
  description = "Database name of the SmithDB PostgreSQL metastore."
  default     = ""
}

variable "smithdb_metastore_username" {
  type        = string
  description = "Username SmithDB uses to connect to its PostgreSQL metastore."
  default     = ""
}

variable "smithdb_metastore_password" {
  type        = string
  description = "Optional SmithDB metastore password; null when Entra authentication is used."
  sensitive   = true
  default     = null
  nullable    = true
}

# ── Blob storage (Azure Workload Identity) ────────────────────────────────────

variable "blob_managed_identity_client_id" {
  type        = string
  description = "Client ID of the User-Assigned Managed Identity used by LangSmith pods to access blob storage (Workload Identity)"
}

variable "backend_service_account_name" {
  type        = string
  description = "Pre-created backend ServiceAccount used by Helm pre-install hooks."
}

variable "smithdb_service_account_name" {
  type        = string
  description = "Pre-created SmithDB ServiceAccount used by Helm pre-install hooks."
  default     = ""
}

variable "smithdb_managed_identity_client_id" {
  type        = string
  description = "Client ID of the SmithDB managed identity."
  default     = ""
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

variable "ingress_controller" {
  type        = string
  description = "Ingress controller in use. Determines which namespace the NetworkPolicy allows ingress from (nginx → ingress-nginx, envoy-gateway → envoy-gateway-system, istio → istio-system, istio-addon → aks-istio-ingress). 'agic' has no in-cluster namespace and is allowed by agic_subnet_cidrs instead."
  default     = "nginx"
}

variable "agic_subnet_cidrs" {
  type        = list(string)
  description = "Address prefixes of the Application Gateway subnet, allowed through the NetworkPolicy by IP range. Only used when ingress_controller = 'agic'."
  default     = []
}

variable "tls_certificate_source" {
  type        = string
  description = "TLS certificate source. 'letsencrypt' = HTTP-01 via cert-manager. 'dns01' = DNS-01 via Azure DNS + Workload Identity. 'none' = skip. Both ClusterIssuers are created by helm/scripts/deploy.sh; this module only sets up cert-manager to support them."
  default     = "letsencrypt"

  validation {
    condition     = contains(["letsencrypt", "dns01", "none"], var.tls_certificate_source)
    error_message = "tls_certificate_source must be 'letsencrypt', 'dns01', or 'none'."
  }
}

variable "cert_manager_identity_client_id" {
  type        = string
  description = "Client ID of the cert-manager Managed Identity. Required when tls_certificate_source = 'dns01'."
  default     = ""
}

# ── KEDA ──────────────────────────────────────────────────────────────────────

variable "keda_version" {
  type        = string
  description = "KEDA Helm chart version"
  default     = "2.14.0"
}
