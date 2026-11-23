# byo_vnet: the data plane uses your VNet. You own the VNet, subnets, NSGs
# and egress. LangSmith joins the subnets and cannot change the network.

locals {
  byo_vnets = {
    for key, data_plane in var.data_planes : key => data_plane.byo_vnet
    if data_plane.byo_vnet != null
  }

  langsmith_byoc_network_actions = [
    "Microsoft.Network/virtualNetworks/read",
    "Microsoft.Network/virtualNetworks/subnets/read",
    # AKS and the private endpoints join the subnets.
    "Microsoft.Network/virtualNetworks/subnets/join/action",
    # The private DNS zones link to the VNet.
    "Microsoft.Network/virtualNetworks/join/action",
    # The preflight checks the AKS identity grant on the AKS subnet.
    "Microsoft.Authorization/roleAssignments/read",
  ]
}

# A custom role needs a resource group scope or larger. It is assigned on the VNet only.
resource "azurerm_role_definition" "langsmith_byoc_network" {
  for_each = local.byo_vnets

  name              = "langsmith-byoc-network-${each.key}-${random_string.key_vault_suffix[each.key].result}"
  scope             = split("/providers/", each.value.vnet_id)[0]
  description       = "LangSmith BYOC: read the VNet and join its subnets."
  assignable_scopes = [split("/providers/", each.value.vnet_id)[0]]

  permissions {
    actions = local.langsmith_byoc_network_actions
  }
}

resource "azurerm_role_assignment" "langsmith_byoc_network" {
  for_each = local.byo_vnets

  scope              = each.value.vnet_id
  role_definition_id = azurerm_role_definition.langsmith_byoc_network[each.key].role_definition_resource_id
  principal_id       = local.langsmith_service_principal_object_id
  principal_type     = "ServicePrincipal"
  description        = var.external_id
}

# AKS puts its nodes and its internal load balancer in the AKS subnet.
resource "azurerm_role_assignment" "aks_subnet" {
  for_each = local.byo_vnets

  scope                = each.value.aks_subnet_id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_user_assigned_identity.data_plane["${each.key}/aks"].principal_id
  principal_type       = "ServicePrincipal"
}

# USER_DEFINED_ROUTING: AKS reads the route table. Azure CNI writes no routes.
resource "azurerm_role_assignment" "aks_route_table" {
  for_each = { for key, network in local.byo_vnets : key => network if network.route_table_id != null }

  scope                = each.value.route_table_id
  role_definition_name = "Reader"
  principal_id         = azurerm_user_assigned_identity.data_plane["${each.key}/aks"].principal_id
  principal_type       = "ServicePrincipal"
}
