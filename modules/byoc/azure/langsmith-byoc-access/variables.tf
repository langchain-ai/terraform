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
  description = "Map of data planes. The key is the data plane name. Each data plane gets a dedicated resource group (langsmith-byoc-<key>) with only a Key Vault in it. Do not add other resources to that resource group: LangSmith deletes the whole resource group when you delete the data plane."
  type = map(object({
    location = string
    tags     = optional(map(string), {})
    # Set to true after the data plane is active. LangSmith then gets the
    # langsmith-byoc-reduced role, which cannot delete the data plane. Set it
    # back to false before you delete or re-create the data plane.
    reduced_access = optional(bool, false)
    # An existing VNet in this subscription, in any resource group. See
    # network.tf. outbound_type is NAT_GATEWAY or USER_DEFINED_ROUTING: the
    # NAT gateway or the route table must already be on the AKS subnet. With
    # USER_DEFINED_ROUTING, the 0.0.0.0/0 route must use a VirtualAppliance or
    # VirtualNetworkGateway next hop.
    existing_network = optional(object({
      vnet_id                = string
      aks_subnet_id          = string
      postgres_subnet_id     = string
      redis_subnet_id        = string
      private_link_subnet_id = string
      outbound_type          = optional(string, "NAT_GATEWAY")
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

  validation {
    condition = alltrue([
      for data_plane in values(var.data_planes) : data_plane.existing_network == null || (
        can(regex("^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft.Network/virtualNetworks/[^/]+$", data_plane.existing_network.vnet_id)) &&
        alltrue([
          for subnet in [
            data_plane.existing_network.aks_subnet_id,
            data_plane.existing_network.postgres_subnet_id,
            data_plane.existing_network.redis_subnet_id,
            data_plane.existing_network.private_link_subnet_id,
          ] : startswith(lower(subnet), "${lower(data_plane.existing_network.vnet_id)}/subnets/")
        ]) &&
        contains(["NAT_GATEWAY", "USER_DEFINED_ROUTING"], data_plane.existing_network.outbound_type)
      )
    ])
    error_message = "existing_network.vnet_id must be a VNet resource ID, each subnet ID must be a subnet of that VNet, and outbound_type must be NAT_GATEWAY or USER_DEFINED_ROUTING."
  }
}

variable "key_vault_purge_protection_enabled" {
  description = "Enable purge protection on each data plane Key Vault. A deleted vault then keeps its name reserved for the soft delete retention period (90 days)."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Tags for all resource groups and Key Vaults that this module creates."
  type        = map(string)
  default     = {}
}
