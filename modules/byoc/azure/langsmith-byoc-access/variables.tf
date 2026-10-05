variable "langsmith_app_client_id" {
  description = "Client ID of the LangSmith multi-tenant Entra application. LangChain gives you this value."
  type        = string
}

variable "external_id" {
  description = "External ID from Settings > Data Planes in the LangSmith UI. The module writes it as the description of each LangSmith role assignment. LangSmith reads it to verify that you own the subscription."
  type        = string

  validation {
    condition     = length(trimspace(var.external_id)) > 0
    error_message = "external_id must not be empty. Copy it from Settings > Data Planes in the LangSmith UI."
  }
}

variable "data_planes" {
  description = "Map of data planes. The key is the data plane name. Each data plane gets a dedicated resource group (langsmith-byoc-<key>) with only the resources of this module in it. Do not add other resources to that resource group: LangSmith deletes the whole resource group when you delete the data plane."
  type = map(object({
    location = string
    tags     = optional(map(string), {})
  }))
  default = {}

  # The key is part of the resource group name (at most 90 characters) and of
  # the Key Vault name, which allows no consecutive hyphens and must start with
  # a letter.
  validation {
    condition = alltrue([
      for key in keys(var.data_planes) :
      can(regex("^[a-z]([a-z0-9-]{0,61}[a-z0-9])?$", key)) && !strcontains(key, "--")
    ])
    error_message = "Each data_planes key must be 1 to 63 characters of lowercase letters, digits, and hyphens, start with a letter, end with a letter or digit, and contain no consecutive hyphens."
  }
}

variable "key_vault_purge_protection_enabled" {
  description = "Enable purge protection on each data plane Key Vault. A deleted vault then keeps its name reserved for the soft delete retention period (90 days)."
  type        = bool
  default     = true
}

variable "byo_iam" {
  description = "Bring your own IAM for every data plane of this module. The module then creates the workload identities, the custom blob role, and their role assignments, and LangSmith gets no User Access Administrator. Set it before you create the data planes in LangSmith."
  type        = bool
  default     = false
}

variable "tags" {
  description = "Tags for all resource groups, Key Vaults, and managed identities that this module creates."
  type        = map(string)
  default     = {}
}
