# Time-bound access for an upgrade that needs the actions reduced_access
# removes. PIM removes the assignments at elevated_until. Requires Microsoft
# Entra ID P2.

locals {
  elevated_role_data_planes = { for key, dp in var.data_planes : key => dp if dp.reduced_access }

  elevated_data_planes = {
    for key, dp in local.elevated_role_data_planes : key => dp
    if dp.elevated_until != null && timecmp(plantimestamp(), coalesce(dp.elevated_until, "2000-01-01T00:00:00Z")) < 0
  }

  elevated_assignments = merge([
    for key, dp in local.elevated_data_planes : merge(
      { "${key}/elevated" = { data_plane = key, role_definition_id = azurerm_role_definition.langsmith_byoc_elevated[key].role_definition_resource_id } },
      dp.byo_iam ? {} : { "${key}/uaa" = { data_plane = key, role_definition_id = data.azurerm_role_definition.user_access_administrator.id } },
    )
  ]...)
}

data "azurerm_role_definition" "user_access_administrator" {
  name  = "User Access Administrator"
  scope = "/subscriptions/${data.azurerm_client_config.current.subscription_id}"
}

# The actions that reduced_access removes. It has no assignment outside an
# elevation window.
resource "azurerm_role_definition" "langsmith_byoc_elevated" {
  for_each = local.elevated_role_data_planes

  name              = "langsmith-byoc-${each.key}-elevated-${random_string.key_vault_suffix[each.key].result}"
  scope             = azurerm_resource_group.data_plane[each.key].id
  description       = "LangSmith BYOC: time-bound access for an upgrade."
  assignable_scopes = [azurerm_resource_group.data_plane[each.key].id]

  permissions {
    actions = [
      for action in local.langsmith_byoc_reduced_removed_actions : action
      if !(each.value.byo_iam && contains(local.langsmith_byoiam_removed_actions, action))
    ]
  }
}

resource "azurerm_pim_active_role_assignment" "langsmith_byoc_elevated" {
  for_each = local.elevated_assignments

  scope              = azurerm_resource_group.data_plane[each.value.data_plane].id
  role_definition_id = each.value.role_definition_id
  principal_id       = azuread_service_principal.langsmith.object_id
  justification      = "LangSmith BYOC upgrade"

  schedule {
    expiration {
      end_date_time = var.data_planes[each.value.data_plane].elevated_until
    }
  }

  lifecycle {
    ignore_changes = [schedule[0].start_date_time]
  }
}
