# ── Required ───────────────────────────────────────────────────────────────────

variable "subscription_id" {
  type        = string
  description = "Azure subscription ID containing the AKS cluster and Key Vault"
}

variable "resource_group_name" {
  type        = string
  description = "Name of the resource group that holds the AKS cluster, Key Vault, and managed identities (created by the infra root)"
}

# ── Naming ─────────────────────────────────────────────────────────────────────

variable "identifier" {
  type        = string
  description = "Suffix appended to resource names (e.g. \"-dev\"). Must match the identifier used when applying the infra root."
  default     = ""
}

# ── Key Vault ──────────────────────────────────────────────────────────────────

variable "key_vault_name" {
  type        = string
  description = "Key Vault name. Defaults to 'langsmith-kv<identifier>' when empty."
  default     = ""
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
  description = "Read postgres-connection-url and postgres-admin-password from Key Vault and pass them to the k8s-bootstrap module"
  default     = true
}

variable "use_external_redis" {
  type        = bool
  description = "Read redis-connection-url from Key Vault and pass it to the k8s-bootstrap module"
  default     = true
}

# ── Ingress / KEDA versions ───────────────────────────────────────────────────
# Set only to pin a version at the root level; otherwise the module default is used.

variable "nginx_ingress_version" {
  type        = string
  description = "ingress-nginx Helm chart version. Empty string (default) resolves the latest chart; pinning is recommended for reproducibility."
  default     = ""
}

variable "keda_version" {
  type        = string
  description = "KEDA Helm chart version. Defaults to the k8s-bootstrap module default (2.14.0) when null."
  default     = null
}
