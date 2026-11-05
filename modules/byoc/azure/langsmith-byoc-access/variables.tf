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
  description = "Map of data planes. The key is the data plane name. Each data plane gets a dedicated resource group (langsmith-byoc-<key>) with only a Key Vault in it. Do not add other resources to that resource group: LangSmith can change and delete resources in it."
  type = map(object({
    location = string
    tags     = optional(map(string), {})
    # Set to true after the data plane is active. The LangSmith role then
    # loses the actions that delete the data plane, and the User Access
    # Administrator assignment goes away. Set it back to false before an
    # upgrade that adds a role assignment, and before you delete or re-create
    # the data plane.
    reduced_access = optional(bool, false)
    # Azure AI Foundry resource IDs. The workload identity of the data plane
    # gets Cognitive Services User on each, so Engine can call them without an
    # API key. Set it after the data plane is active.
    engine_foundry_resource_ids = optional(list(string), [])
  }))

  validation {
    condition     = length(var.data_planes) > 0
    error_message = "data_planes must have at least one data plane."
  }

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

variable "tags" {
  description = "Tags for all resource groups and Key Vaults that this module creates."
  type        = map(string)
  default     = {}
}
