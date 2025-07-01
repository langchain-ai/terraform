resource "azurerm_kubernetes_cluster" "main" {
  name                = var.cluster_name
  location            = var.location
  resource_group_name = var.resource_group_name
  dns_prefix          = var.cluster_name
  kubernetes_version  = var.kubernetes_version

  default_node_pool {
    name                        = "default"
    vm_size                     = var.default_node_pool_vm_size
    auto_scaling_enabled        = true
    min_count                   = 1
    max_count                   = var.default_node_pool_max_count
    vnet_subnet_id              = var.subnet_id
    temporary_name_for_rotation = "defaulttmp"
  }

  identity {
    type = "SystemAssigned"
  }

  network_profile {
    network_plugin = "azure"
    service_cidr   = var.service_cidr
    dns_service_ip = var.dns_service_ip
  }

  lifecycle {
    ignore_changes = [
      default_node_pool[0].upgrade_settings
    ]
  }
}

# Other node pools
resource "azurerm_kubernetes_cluster_node_pool" "node_pool" {
  for_each = var.additional_node_pools

  name                        = each.key
  kubernetes_cluster_id       = azurerm_kubernetes_cluster.main.id
  vm_size                     = each.value.vm_size
  auto_scaling_enabled        = true
  vnet_subnet_id              = var.subnet_id
  min_count                   = each.value.min_count
  max_count                   = each.value.max_count
  mode                        = "User"
  temporary_name_for_rotation = "${each.key}tmp"
}
