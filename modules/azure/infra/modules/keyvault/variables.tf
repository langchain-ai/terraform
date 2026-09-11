variable "name" {
  type        = string
  description = "Key Vault name. Must be globally unique, 3-24 chars, alphanumeric + hyphens. e.g. 'langsmith-kv-prod'. Only used when create_keyvault = true."
}

# ── Create or attach ──────────────────────────────────────────────────────────

variable "create_keyvault" {
  type        = bool
  description = "Whether to create a new Key Vault. Set false to attach to a pre-existing one — provide existing_keyvault_name and existing_keyvault_resource_group_name. On the attach path this module writes its secrets into that vault and changes nothing else about it, so location, sku, soft_delete_retention_days, purge_protection_enabled, network_default_action, allowed_ips, and allowed_subnet_ids are all ignored."
  default     = true
}

variable "existing_keyvault_name" {
  type        = string
  description = "Name of the pre-existing Key Vault to attach to. Required when create_keyvault = false; leaving it empty fails the plan rather than falling back to a derived name."
  default     = ""

  validation {
    condition     = var.existing_keyvault_name == "" || can(regex("^[A-Za-z][A-Za-z0-9-]{1,22}[A-Za-z0-9]$", var.existing_keyvault_name))
    error_message = "existing_keyvault_name must be a valid Key Vault name: 3-24 characters, alphanumeric and hyphens, starting with a letter and not ending in a hyphen."
  }
}

variable "existing_keyvault_resource_group_name" {
  type        = string
  description = "Resource group containing the pre-existing Key Vault. Required when create_keyvault = false. No default is derived: the only name this module could guess is the resource group it creates, which is not where a vault the customer's platform team owns lives."
  default     = ""
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

variable "terraform_principal_type" {
  type        = string
  description = "Principal type of the identity running `terraform apply`, applied to its 'Key Vault Secrets Officer' grant. Null (default) omits the field and lets Azure infer it. Set \"User\" or \"ServicePrincipal\" only when the subscription delegates roleAssignments/write through an ABAC condition on principalType, which rejects requests that omit it."
  default     = null

  validation {
    condition     = var.terraform_principal_type == null ? true : contains(["User", "Group", "ServicePrincipal"], var.terraform_principal_type)
    error_message = "terraform_principal_type must be 'User', 'Group', or 'ServicePrincipal'. Omit it entirely (or set null) to let Azure infer the type — an empty string is not a valid opt-out."
  }
}

variable "manage_terraform_admin_assignment" {
  type        = bool
  description = "Whether this module creates the deployer's 'Key Vault Secrets Officer' grant. True is the behaviour this module has always had, so a caller that does not set it is unaffected. The root module passes create_keyvault, so a vault this module creates gets the grant and a customer-owned one does not, because creating it there means calling Microsoft.Authorization/roleAssignments/write on a resource the platform team owns. When false, the deployer must already hold read and write on secrets from a grant made outside this apply, or the secret writes fail with 403."
  default     = true
}

variable "manage_managed_identity_assignment" {
  type        = bool
  description = "Whether this module creates the pod managed identity's 'Key Vault Secrets User' grant. Gated separately from manage_terraform_admin_assignment because the two requests carry different principal types, and a subscription that delegates roleAssignments/write through an ABAC condition on principalType can permit one and reject the other: this principal is always a service principal, while the deployer is a user under an interactive `az login`. Nobody can pre-grant this one, because the identity is created partway through the same apply, so leave it true wherever the deployer is allowed to create it at all."
  default     = true
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
# Only secrets Terraform already holds for another reason. The LangSmith app
# secrets are seeded post-apply by infra/scripts/seed-keyvault-secrets.sh so
# they never land in Terraform state.

variable "postgres_admin_password" {
  type        = string
  description = "PostgreSQL administrator password"
  sensitive   = true
}

variable "langsmith_license_key" {
  type        = string
  description = "LangSmith enterprise license key"
  sensitive   = true
  default     = ""
}

# ── Tags ──────────────────────────────────────────────────────────────────────

variable "tags" {
  type        = map(string)
  description = "Common Azure resource tags to apply to all resources in this module"
  default     = {}
}
