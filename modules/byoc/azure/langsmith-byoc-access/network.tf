# An existing VNet for a data plane (existing_network). You keep the VNet,
# its subnets, NSGs, and egress. LangSmith joins the subnets and links its
# private DNS zones to the VNet. It never changes the network.
locals {
  existing_networks = {
    for key, data_plane in var.data_planes : key => merge(data_plane.existing_network, {
      # Custom roles can only use resource groups, subscriptions, and management
      # groups as assignable scopes, so the role uses the resource group of the VNet.
      resource_group_id = regex("^(/subscriptions/[^/]+/resourceGroups/[^/]+)/", data_plane.existing_network.vnet_id)[0]
    }) if data_plane.existing_network != null
  }

  langsmith_byoc_network_actions = [
    "Microsoft.Network/virtualNetworks/read",
    "Microsoft.Network/virtualNetworks/subnets/read",
    # AKS, the private endpoints, and the Blob firewall use the subnets.
    "Microsoft.Network/virtualNetworks/subnets/join/action",
    "Microsoft.Network/virtualNetworks/subnets/joinViaServiceEndpoint/action",
    # The LangSmith private DNS zones link to the VNet.
    "Microsoft.Network/virtualNetworks/join/action",
    # LangSmith checks that the AKS identity has a role on the AKS subnet.
    "Microsoft.Authorization/roleAssignments/read",
  ]
}

resource "azurerm_role_definition" "langsmith_byoc_network" {
  for_each = local.existing_networks

  name              = "langsmith-byoc-network-${each.key}-${random_string.key_vault_suffix[each.key].result}"
  scope             = each.value.resource_group_id
  description       = "LangSmith BYOC: use the subnets of an existing VNet. The role cannot change the network."
  assignable_scopes = [each.value.resource_group_id]

  permissions {
    actions = local.langsmith_byoc_network_actions
  }
}

# Scoped to the VNet only. The description is the external ID, as on the data
# plane resource group.
resource "azurerm_role_assignment" "langsmith_byoc_network" {
  for_each = local.existing_networks

  scope              = each.value.vnet_id
  role_definition_id = azurerm_role_definition.langsmith_byoc_network[each.key].role_definition_resource_id
  principal_id       = azuread_service_principal.langsmith.object_id
  principal_type     = "ServicePrincipal"
  description        = var.external_id
}

# The AKS cluster identity. AKS uses it to put nodes and the internal load
# balancer in the AKS subnet. You create it, so that LangSmith needs no access
# to change roles on your network. LangSmith assigns it to the cluster through
# its role on the data plane resource group.
resource "azurerm_user_assigned_identity" "aks" {
  for_each = local.existing_networks

  name                = "langsmith-byoc-${each.key}-aks"
  location            = azurerm_resource_group.data_plane[each.key].location
  resource_group_name = azurerm_resource_group.data_plane[each.key].name
  tags                = merge(var.tags, var.data_planes[each.key].tags)
}

resource "azurerm_role_assignment" "aks_subnet" {
  for_each = local.existing_networks

  scope                = each.value.aks_subnet_id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_user_assigned_identity.aks[each.key].principal_id
  principal_type       = "ServicePrincipal"
}
