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
    # Let LangSmith put an Azure Firewall on the outbound traffic of the data
    # plane. Adds the actions in local.langsmith_byoc_firewall_actions.
    egress_firewall = optional(bool, false)
    # Use your VNet. LangSmith joins the two subnets and cannot change the
    # network. Needs byo_iam. Do not change after creation. See network.tf.
    byo_vnet = optional(object({
      vnet_id                     = string
      aks_subnet_id               = string
      private_endpoints_subnet_id = string
      # The egress that you attach to the AKS subnet: NAT_GATEWAY, or
      # USER_DEFINED_ROUTING for a route table with a 0.0.0.0/0 route.
      outbound_type = optional(string, "NAT_GATEWAY")
    }))
    # VNet flow logs in your storage account. Set it after the data plane is
    # active. Remove it before you delete the data plane. See flow_logs.tf.
    flow_logs = optional(object({
      storage_account_id = string
      retention_days     = optional(number, 30)
      # Leave empty to use the Network Watcher of the region.
      network_watcher_name                = optional(string)
      network_watcher_resource_group_name = optional(string, "NetworkWatcherRG")
    }))
    # Time-bound access to the data plane for LangChain engineers. See
    # break_glass.tf.
    break_glass = optional(object({
      # Object IDs in your tenant: guest users or a group.
      principal_ids = list(string)
      # RFC 3339 time, for example "2026-11-12T18:00:00Z".
      until           = string
      kubernetes_role = optional(string, "Azure Kubernetes Service RBAC Reader")
    }))
  }))
  default = {}

  validation {
    condition = alltrue([
      for dp in values(var.data_planes) : dp.break_glass == null || can(timecmp(dp.break_glass.until, "2000-01-01T00:00:00Z"))
    ])
    error_message = "break_glass.until must be an RFC 3339 time, for example 2026-11-12T18:00:00Z."
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

  # flow_logs.tf finds the VNet in the data plane resource group, so it cannot
  # apply to your VNet.
  validation {
    condition = alltrue([
      for data_plane in values(var.data_planes) : (
        data_plane.byo_iam && data_plane.flow_logs == null &&
        can(regex("^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft.Network/virtualNetworks/[^/]+$", data_plane.byo_vnet.vnet_id)) &&
        startswith(data_plane.byo_vnet.aks_subnet_id, "${data_plane.byo_vnet.vnet_id}/subnets/") &&
        startswith(data_plane.byo_vnet.private_endpoints_subnet_id, "${data_plane.byo_vnet.vnet_id}/subnets/") &&
        contains(["NAT_GATEWAY", "USER_DEFINED_ROUTING"], data_plane.byo_vnet.outbound_type)
      ) if data_plane.byo_vnet != null
    ])
    error_message = "byo_vnet needs byo_iam = true and no flow_logs. vnet_id must be a VNet resource ID, the two subnets must be in that VNet, and outbound_type must be NAT_GATEWAY or USER_DEFINED_ROUTING."
  }
}

variable "tags" {
  description = "Tags for all resource groups and Key Vaults that this module creates."
  type        = map(string)
  default     = {}
}
