resource "azurerm_postgresql_flexible_server" "db" {
  name                          = var.name
  resource_group_name           = var.resource_group_name
  location                      = var.location
  version                       = var.postgres_version

  storage_mb   = var.storage_mb
  storage_tier = var.storage_tier
  sku_name   = var.sku_name

  administrator_login           = var.admin_username
  administrator_password        = var.admin_password

  public_network_access_enabled = false
  delegated_subnet_id = var.subnet_id
  private_dns_zone_id = azurerm_private_dns_zone.db_dns_zone.id

  lifecycle {
    ignore_changes = [zone]
  }
}

# Private DNS zone needed when using a delegated subnet for the database
resource "azurerm_private_dns_zone" "db_dns_zone" {
  name                = "privatelink.postgres.database.azure.com"
  resource_group_name = var.resource_group_name
}

resource "azurerm_private_dns_zone_virtual_network_link" "dns_zone_vnet_link" {
  name                  = "${var.name}-link"
  resource_group_name   = var.resource_group_name
  private_dns_zone_name = azurerm_private_dns_zone.db_dns_zone.name
  virtual_network_id    = var.vnet_id
  registration_enabled  = false
}

# These are extensions that are required for a full LangSmith deployment
resource "azurerm_postgresql_flexible_server_configuration" "extensions" {
  name                = "azure.extensions"
  server_id           = azurerm_postgresql_flexible_server.db.id
  value               = "PGCRYPTO,BTREE_GIN,PG_TRGM,BTREE_GIST,CITEXT"
}

resource "azurerm_postgresql_flexible_server_configuration" "max_connections" {
  name      = "max_connections"
  server_id = azurerm_postgresql_flexible_server.db.id
  value     = var.max_connections
}
