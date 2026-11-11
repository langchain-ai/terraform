# VNet flow logs for each data plane that sets flow_logs. LangSmith has no
# access to the flow log or the storage account.

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

# A subscription has one Network Watcher in each region.
data "azurerm_resources" "network_watchers" {
  count = length(local.flow_log_data_planes) > 0 ? 1 : 0

  type = "Microsoft.Network/networkWatchers"
}

locals {
  network_watchers = {
    for key, data_plane in local.flow_log_data_planes : key => (
      data_plane.flow_logs.network_watcher_name != null
      ? { name = data_plane.flow_logs.network_watcher_name, resource_group_name = data_plane.flow_logs.network_watcher_resource_group_name }
      : one([
        for watcher in data.azurerm_resources.network_watchers[0].resources :
        { name = watcher.name, resource_group_name = watcher.resource_group_name }
        if watcher.location == azurerm_resource_group.data_plane[key].location
      ])
    )
  }
}

resource "azurerm_network_watcher_flow_log" "data_plane" {
  for_each = local.flow_log_data_planes

  name                 = "langsmith-byoc-${each.key}"
  network_watcher_name = local.network_watchers[each.key].name
  resource_group_name  = local.network_watchers[each.key].resource_group_name
  target_resource_id   = one(data.azurerm_resources.vnet[each.key].resources).id
  storage_account_id   = each.value.flow_logs.storage_account_id
  enabled              = true
  version              = 2

  retention_policy {
    enabled = true
    days    = each.value.flow_logs.retention_days
  }

  tags = merge(var.tags, each.value.tags)

  lifecycle {
    precondition {
      condition     = local.network_watchers[each.key] != null
      error_message = "The region of data plane ${each.key} has no Network Watcher. Create one, or set network_watcher_name."
    }
  }
}
