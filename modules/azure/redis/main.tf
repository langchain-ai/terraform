resource "azurerm_redis_cache" "redis" {
  name                 = var.name
  location             = var.location
  resource_group_name  = var.resource_group_name
  capacity             = var.capacity
  family               = var.family
  sku_name             = var.sku_name
  subnet_id            = var.subnet_id
  public_network_access_enabled = false
}

resource "azurerm_redis_enterprise_cluster" "main" {
  count = var.enable_redis_cluster ? 1 : 0

  name                = "${var.name}-cluster"
  location            = var.location
  resource_group_name = var.resource_group_name
  sku_name            = var.redis_cluster_sku_name
}

resource "azurerm_redis_enterprise_database" "db" {
  count = var.enable_redis_cluster ? 1 : 0
  cluster_id          = azurerm_redis_enterprise_cluster.main[0].id
}
