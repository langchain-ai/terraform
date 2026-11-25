variable "langsmith_app_client_id" {
  description = "Client ID of the LangSmith multi-tenant Entra application. LangChain gives you this value."
  type        = string
}

variable "create_service_principal" {
  description = "true: create or update the LangSmith service principal (needs Entra ID permission). false: only read it, after an Entra admin ran `az ad sp create`. Do not change from true to false later, or Terraform deletes it."
  type        = bool
  default     = true
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
    # Let LangSmith turn on dedicated deployments, each with its own PostgreSQL
    # flexible server in the resource group. With byo_iam, the module creates
    # the host-backend identity and its roles in identities.tf. Without it,
    # LangSmith creates them itself and this setting changes nothing.
    dedicated_deployments = optional(bool, false)
    # Let LangSmith build GitHub deployments and langgraph deploy images in the
    # cluster, pushing to a container registry in the resource group. With
    # byo_iam, the module creates the build and host-backend identities and
    # their roles in deployment_builds.tf; set it after the data plane is
    # active. Without byo_iam, LangSmith creates them itself and this setting
    # changes nothing.
    deployment_builds = optional(bool, false)
    # Use your VNet. Needs byo_iam. Do not change after creation. See network.tf.
    byo_vnet = optional(object({
      vnet_id                     = string
      aks_subnet_id               = string
      private_endpoints_subnet_id = string
      # NAT_GATEWAY, or USER_DEFINED_ROUTING for a route table with 0.0.0.0/0.
      outbound_type = optional(string, "NAT_GATEWAY")
      # The route table of the AKS subnet. Only with USER_DEFINED_ROUTING.
      route_table_id = optional(string)
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

  # flow_logs and dedicated_deployments need a VNet that LangSmith creates.
  validation {
    condition = alltrue([
      for data_plane in values(var.data_planes) : (
        data_plane.byo_iam && data_plane.flow_logs == null && !data_plane.dedicated_deployments &&
        can(regex("^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft.Network/virtualNetworks/[^/]+$", data_plane.byo_vnet.vnet_id)) &&
        startswith(data_plane.byo_vnet.aks_subnet_id, "${data_plane.byo_vnet.vnet_id}/subnets/") &&
        startswith(data_plane.byo_vnet.private_endpoints_subnet_id, "${data_plane.byo_vnet.vnet_id}/subnets/") &&
        contains(["NAT_GATEWAY", "USER_DEFINED_ROUTING"], data_plane.byo_vnet.outbound_type) &&
        (data_plane.byo_vnet.outbound_type == "USER_DEFINED_ROUTING") == (data_plane.byo_vnet.route_table_id != null) &&
        (data_plane.byo_vnet.route_table_id == null || can(regex("^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft.Network/routeTables/[^/]+$", data_plane.byo_vnet.route_table_id)))
      ) if data_plane.byo_vnet != null
    ])
    error_message = "byo_vnet needs byo_iam, and no flow_logs or dedicated_deployments. Both subnets must be in vnet_id. outbound_type is NAT_GATEWAY or USER_DEFINED_ROUTING. route_table_id is required with USER_DEFINED_ROUTING only."
  }
}

variable "tags" {
  description = "Tags for all resource groups and Key Vaults that this module creates."
  type        = map(string)
  default     = {}
}
