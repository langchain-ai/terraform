locals {
  engine_foundry_data_planes = {
    for key, data_plane in var.data_planes : key => data_plane
    if data_plane.engine_foundry_resource_id != null
  }

  # With byo_iam this module creates the workload identity. Otherwise
  # LangSmith creates it, so the module looks it up.
  engine_lookup_data_planes = {
    for key, data_plane in local.engine_foundry_data_planes : key => data_plane
    if !data_plane.byo_iam
  }
}

data "azurerm_resources" "engine_identities" {
  for_each = local.engine_lookup_data_planes

  resource_group_name = "langsmith-byoc-${each.key}"
  type                = "Microsoft.ManagedIdentity/userAssignedIdentities"
}

# LangSmith names the identity langsmith-workload-identity. Data planes created
# before that name use <prefix>-smith-workload-identity.
data "azurerm_user_assigned_identity" "engine" {
  for_each = local.engine_lookup_data_planes

  name = (
    contains(data.azurerm_resources.engine_identities[each.key].resources[*].name, "langsmith-workload-identity")
    ? "langsmith-workload-identity"
    : one([for identity in data.azurerm_resources.engine_identities[each.key].resources : identity.name if endswith(identity.name, "-smith-workload-identity")])
  )
  resource_group_name = "langsmith-byoc-${each.key}"
}

# Cognitive Services User allows inference on Claude and GPT. Cognitive
# Services OpenAI User allows only the OpenAI models.
resource "azurerm_role_assignment" "engine_foundry" {
  for_each = local.engine_foundry_data_planes

  scope                = each.value.engine_foundry_resource_id
  role_definition_name = "Cognitive Services User"
  principal_id = (
    each.value.byo_iam
    ? azurerm_user_assigned_identity.data_plane["${each.key}/workload"].principal_id
    : data.azurerm_user_assigned_identity.engine[each.key].principal_id
  )
  principal_type = "ServicePrincipal"
}
