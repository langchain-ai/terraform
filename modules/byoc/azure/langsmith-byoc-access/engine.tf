# Optional: lets LangSmith Engine call Azure AI Foundry without an API key,
# through the workload identity of the data plane. LangSmith creates that
# identity, but its roles stop at the data plane resource group, so it cannot
# grant a role on a Foundry resource.

locals {
  engine_foundry_data_planes = {
    for key, data_plane in var.data_planes : key => data_plane
    if data_plane.engine_foundry_resource_id != null
  }
}

data "azurerm_resources" "engine_identities" {
  for_each = local.engine_foundry_data_planes

  resource_group_name = "langsmith-byoc-${each.key}"
  type                = "Microsoft.ManagedIdentity/userAssignedIdentities"
}

# LangSmith names it <prefix>-smith-workload-identity.
data "azurerm_user_assigned_identity" "engine" {
  for_each = local.engine_foundry_data_planes

  name                = one([for identity in data.azurerm_resources.engine_identities[each.key].resources : identity.name if endswith(identity.name, "-smith-workload-identity")])
  resource_group_name = "langsmith-byoc-${each.key}"
}

# Cognitive Services User allows inference on Claude and GPT. Cognitive
# Services OpenAI User allows only the OpenAI models.
resource "azurerm_role_assignment" "engine_foundry" {
  for_each = local.engine_foundry_data_planes

  scope                = each.value.engine_foundry_resource_id
  role_definition_name = "Cognitive Services User"
  principal_id         = data.azurerm_user_assigned_identity.engine[each.key].principal_id
  principal_type       = "ServicePrincipal"
}
