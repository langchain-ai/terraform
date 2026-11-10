locals {
  engine_foundry_data_planes = {
    for key, data_plane in var.data_planes : key => data_plane
    if data_plane.engine_foundry_resource_id != null
  }
}

# The workload identity of the data plane. With byo_iam this module creates
# it; otherwise LangSmith does, with the same name.
data "azurerm_user_assigned_identity" "engine" {
  for_each = local.engine_foundry_data_planes

  name                = "langsmith-workload-identity"
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
