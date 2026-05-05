variable "name" {
  type        = string
  description = "Key Vault name. Must be globally unique, 3-24 chars, alphanumeric + hyphens. e.g. 'langsmith-kv-prod'"
}

variable "location" {
  type        = string
  description = "Azure region"
}

variable "resource_group_name" {
  type        = string
  description = "Resource group to deploy the Key Vault into"
}

# ── RBAC ──────────────────────────────────────────────────────────────────────

variable "managed_identity_principal_id" {
  type        = string
  description = "Principal ID of the user-assigned managed identity used by LangSmith K8s pods. Gets 'Key Vault Secrets User' role to read secrets at runtime."
}

# ── Vault configuration ───────────────────────────────────────────────────────

variable "soft_delete_retention_days" {
  type        = number
  description = "Days to retain deleted Key Vault and secrets (7–90). Cannot be reduced after creation."
  default     = 90
}

variable "purge_protection_enabled" {
  type        = bool
  description = "Prevent permanent deletion of the vault during the soft-delete retention period. Recommended true for production; set false for dev environments where you need to destroy and recreate quickly."
  default     = true
}

variable "network_default_action" {
  type        = string
  description = "Default action for the Key Vault data-plane firewall. \"Allow\" (default) keeps the starter UX working — Terraform's first apply creates ~10 secrets via the data plane and \"Deny\" without operator IP allowlisting blocks that. Production deployments set \"Deny\" and populate allowed_ips / allowed_subnet_ids."
  default     = "Allow"

  validation {
    condition     = contains(["Allow", "Deny"], var.network_default_action)
    error_message = "network_default_action must be 'Allow' or 'Deny'."
  }
}

variable "allowed_ips" {
  type        = list(string)
  description = "Public IPs / CIDRs allowed through the Key Vault firewall when network_default_action = \"Deny\". Operator workstations, CI runners, or jumpboxes that legitimately need to call the data plane."
  default     = []
}

variable "allowed_subnet_ids" {
  type        = list(string)
  description = "Subnet IDs allowlisted via the Microsoft.KeyVault service endpoint. Typically the AKS subnet so pods can read secrets while the rest of the internet is denied. The subnet must have service_endpoints = [\"Microsoft.KeyVault\", ...] configured."
  default     = []
}

# ── Secrets ───────────────────────────────────────────────────────────────────

variable "postgres_admin_password" {
  type        = string
  description = "PostgreSQL administrator password"
  sensitive   = true
}

variable "langsmith_admin_password" {
  type        = string
  description = "LangSmith UI admin account password"
  sensitive   = true
  default     = ""
}

variable "langsmith_license_key" {
  type        = string
  description = "LangSmith enterprise license key"
  sensitive   = true
  default     = ""
}

variable "langsmith_api_key_salt" {
  type        = string
  description = "Salt used to hash LangSmith API keys. Keep stable — changing it invalidates all existing API keys."
  sensitive   = true
}

variable "langsmith_jwt_secret" {
  type        = string
  description = "JWT signing secret for LangSmith sessions. Keep stable."
  sensitive   = true
}

variable "langsmith_deployments_encryption_key" {
  type        = string
  description = "Fernet encryption key for LangGraph Platform deployments. Empty = not stored."
  sensitive   = true
  default     = ""
}

variable "langsmith_agent_builder_encryption_key" {
  type        = string
  description = "Fernet encryption key for Agent Builder. Empty = not stored."
  sensitive   = true
  default     = ""
}

variable "langsmith_insights_encryption_key" {
  type        = string
  description = "Fernet encryption key for LangSmith Insights. Empty = not stored."
  sensitive   = true
  default     = ""
}

variable "langsmith_polly_encryption_key" {
  type        = string
  description = "Fernet encryption key for Polly agent. Empty = not stored."
  sensitive   = true
  default     = ""
}

# ── Tags ──────────────────────────────────────────────────────────────────────

variable "tags" {
  type        = map(string)
  description = "Common Azure resource tags to apply to all resources in this module"
  default     = {}
}
