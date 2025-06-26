resource "azurerm_kubernetes_cluster" "main" {
  name                = var.cluster_name
  location            = var.location
  resource_group_name = var.resource_group_name
  dns_prefix         = var.cluster_name
  kubernetes_version = var.kubernetes_version

  default_node_pool {
    name                = "default"
    vm_size            = var.default_node_pool_vm_size
    auto_scaling_enabled = true
    min_count          = 1
    max_count          = 10
    vnet_subnet_id     = var.subnet_id
    temporary_name_for_rotation = "defaulttmp"
  }

  identity {
    type = "SystemAssigned"
  }

  network_profile {
    network_plugin    = "azure"
    service_cidr = "10.0.64.0/20"
    dns_service_ip = "10.0.64.10"
  }
}

# Larger node pool
resource "azurerm_kubernetes_cluster_node_pool" "large" {
  count = var.large_node_pool_enabled ? 1 : 0

  name                  = "large"
  kubernetes_cluster_id = azurerm_kubernetes_cluster.main.id
  vm_size              = var.large_node_pool_vm_size
  auto_scaling_enabled   = true
  vnet_subnet_id         = var.subnet_id
  min_count            = 0
  max_count            = 2
  mode                 = "User"
  temporary_name_for_rotation = "largetmp"
}
