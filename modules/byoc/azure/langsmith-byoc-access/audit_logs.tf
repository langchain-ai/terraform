# AKS audit logs for the data planes that set audit_logs. You own the
# diagnostic setting and the storage account. LangSmith cannot change them.

locals {
  audit_log_data_planes = {
    for key, data_plane in var.data_planes : key => data_plane
    if data_plane.audit_logs != null
  }
}

# LangSmith creates one AKS cluster in the data plane resource group.
data "azurerm_resources" "aks" {
  for_each = local.audit_log_data_planes

  resource_group_name = "langsmith-byoc-${each.key}"
  type                = "Microsoft.ContainerService/managedClusters"
}

resource "azurerm_monitor_diagnostic_setting" "audit_logs" {
  for_each = local.audit_log_data_planes

  name               = "langsmith-byoc-${each.key}"
  target_resource_id = one(data.azurerm_resources.aks[each.key].resources).id
  storage_account_id = each.value.audit_logs.storage_account_id

  # The Kubernetes API calls, without get and list.
  enabled_log {
    category = "kube-audit-admin"
  }

  # The Entra ID authentication and the Azure RBAC checks.
  enabled_log {
    category = "guard"
  }
}
