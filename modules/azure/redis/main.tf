resource "azurerm_redis_cache" "redis" {
  name                          = var.name
  location                      = var.location
  resource_group_name           = var.resource_group_name
  capacity                      = var.capacity
  family                        = var.family
  sku_name                      = var.sku_name
  subnet_id                     = var.subnet_id
  public_network_access_enabled = false
}
