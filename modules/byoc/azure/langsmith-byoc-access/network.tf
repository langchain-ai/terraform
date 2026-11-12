# The data planes that set byo_vnet use your VNet. You keep the VNet,
# its subnets, its NSGs, and its egress. LangSmith joins the subnets and links
# the private DNS zones of the data plane to the VNet. It cannot change the
# network.

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
    # LangSmith checks the role of the AKS identity on the AKS subnet.
    "Microsoft.Authorization/roleAssignments/read",
  ]
}

# Azure limits a custom role to a resource group or a larger scope, so the
# role is in the resource group of the VNet.
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

# Scoped to the VNet only.
resource "azurerm_role_assignment" "langsmith_byoc_network" {
  for_each = local.byo_vnets

  scope              = each.value.vnet_id
  role_definition_id = azurerm_role_definition.langsmith_byoc_network[each.key].role_definition_resource_id
  principal_id       = azuread_service_principal.langsmith.object_id
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
