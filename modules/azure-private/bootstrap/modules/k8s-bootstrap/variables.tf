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

# ── Application secrets ───────────────────────────────────────────────────────
# This module intentionally creates ONLY the Postgres/Redis connection secrets.
# The app-config secret (license key, api_key_salt, jwt_secret, admin_password,
# and the feature encryption keys) is created as `langsmith-config-secret` by
# infra/scripts/create-k8s-secrets.sh, which reads every key from Key Vault and
# uses the exact key names the LangSmith chart consumes via
# config.existingSecretName. Keeping that set in the script (not Terraform)
# avoids storing the full app-secret set in Terraform state. See DEPLOYMENT.md
# Phase 3.5.

# ── Ingress / KEDA versions ───────────────────────────────────────────────────

variable "nginx_ingress_version" {
  type        = string
  description = "ingress-nginx Helm chart version. Empty string = resolve latest (pinning is recommended for reproducibility)."
  default     = ""
}

variable "keda_version" {
  type        = string
  description = "KEDA Helm chart version"
  default     = "2.14.0"
}
