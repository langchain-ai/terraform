# VNet flow logs for the data planes that set flow_logs. You own the flow log
# and the storage account. LangSmith gets no access to them.

locals {
  flow_log_data_planes = {
    for key, data_plane in var.data_planes : key => data_plane
    if data_plane.flow_logs != null
  }
}

# LangSmith creates one VNet in the data plane resource group.
data "azurerm_resources" "vnet" {
  for_each = local.flow_log_data_planes

  resource_group_name = "langsmith-byoc-${each.key}"
  type                = "Microsoft.Network/virtualNetworks"
}

resource "azurerm_network_watcher_flow_log" "data_plane" {
  for_each = local.flow_log_data_planes

  name                 = "langsmith-byoc-${each.key}"
  network_watcher_name = coalesce(each.value.flow_logs.network_watcher_name, "NetworkWatcher_${azurerm_resource_group.data_plane[each.key].location}")
  resource_group_name  = each.value.flow_logs.network_watcher_resource_group_name
  target_resource_id   = one(data.azurerm_resources.vnet[each.key].resources).id
  storage_account_id   = each.value.flow_logs.storage_account_id
  enabled              = true
  version              = 2

  retention_policy {
    enabled = true
    days    = each.value.flow_logs.retention_days
  }

  tags = merge(var.tags, each.value.tags)
}
