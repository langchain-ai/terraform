# Time-bound access to a data plane for LangChain engineers. PIM removes the
# assignments at break_glass.until. Requires Microsoft Entra ID P2.

locals {
  # Reader reads the Azure resources. Cluster User Role gets the kubeconfig,
  # which holds no secret. kubernetes_role is the access in the cluster.
  # try(): Terraform evaluates both sides of &&.
  break_glass_assignments = merge([
    for key, dp in var.data_planes : {
      for pair in setproduct(dp.break_glass.principal_ids, ["Reader", "Azure Kubernetes Service Cluster User Role", dp.break_glass.kubernetes_role]) :
      "${key}/${pair[0]}/${pair[1]}" => { data_plane = key, principal_id = pair[0], role = pair[1] }
    }
    if dp.break_glass != null && timecmp(plantimestamp(), try(dp.break_glass.until, "2000-01-01T00:00:00Z")) < 0
  ]...)
}

data "azurerm_role_definition" "break_glass" {
  for_each = toset([for assignment in local.break_glass_assignments : assignment.role])

  name  = each.value
  scope = "/subscriptions/${data.azurerm_client_config.current.subscription_id}"
}

resource "azurerm_pim_active_role_assignment" "break_glass" {
  for_each = local.break_glass_assignments

  scope              = azurerm_resource_group.data_plane[each.value.data_plane].id
  role_definition_id = data.azurerm_role_definition.break_glass[each.value.role].id
  principal_id       = each.value.principal_id
  justification      = "LangSmith BYOC break glass"

  schedule {
    expiration {
      end_date_time = var.data_planes[each.value.data_plane].break_glass.until
    }
  }

  # Azure sets the start time.
  lifecycle {
    ignore_changes = [schedule[0].start_date_time]
  }
}
