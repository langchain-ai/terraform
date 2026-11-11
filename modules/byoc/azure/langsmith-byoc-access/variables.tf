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
    # Create the identities and role assignments yourself. LangSmith gets no
    # User Access Administrator. Do not change after creation.
    byo_iam = optional(bool, false)
    # Azure AI Foundry resource ID. The workload identity of the data plane
    # gets Cognitive Services User on it, so Engine can call it without an API
    # key. Set it after the data plane is active.
    engine_foundry_resource_id = optional(string)
    # Let LangSmith turn on deployment observability: Monitoring charts and
    # searchable log history for LangGraph deployments, kept in a Log
    # Analytics workspace and an Azure Monitor workspace in the resource group.
    # Adds the actions in local.langsmith_byoc_observability_actions.
    deployment_observability = optional(bool, false)
    # VNet flow logs in your storage account. Set it after the data plane is
    # active. Remove it before you delete the data plane. See flow_logs.tf.
    flow_logs = optional(object({
      storage_account_id = string
      retention_days     = optional(number, 30)
      # Leave empty to use the Network Watcher of the region.
      network_watcher_name                = optional(string)
      network_watcher_resource_group_name = optional(string, "NetworkWatcherRG")
    }))
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

variable "tags" {
  description = "Tags for all resource groups and Key Vaults that this module creates."
  type        = map(string)
  default     = {}
}
