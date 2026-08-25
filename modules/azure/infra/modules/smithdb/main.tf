locals {
  create_private_dns_zone = var.private_dns_zone_id == null
  private_dns_zone_id     = local.create_private_dns_zone ? azurerm_private_dns_zone.smithdb[0].id : var.private_dns_zone_id
  use_entra_auth          = var.metastore_admin_password == null
}

data "azurerm_client_config" "current" {}

resource "azurerm_private_dns_zone" "smithdb" {
  count               = local.create_private_dns_zone ? 1 : 0
  name                = "privatelink.postgres.database.azure.com"
  resource_group_name = var.resource_group_name
  tags                = merge(var.tags, { module = "smithdb" })
}

resource "azurerm_private_dns_zone_virtual_network_link" "smithdb" {
  count                 = local.create_private_dns_zone ? 1 : 0
  name                  = "${var.name}-postgres-link"
  resource_group_name   = var.resource_group_name
  private_dns_zone_name = azurerm_private_dns_zone.smithdb[0].name
  virtual_network_id    = var.vnet_id
  registration_enabled  = false
  tags                  = merge(var.tags, { module = "smithdb" })
}

resource "azurerm_postgresql_flexible_server" "metastore" {
  name                          = "${var.name}-metastore"
  resource_group_name           = var.resource_group_name
  location                      = var.location
  version                       = "18"
  delegated_subnet_id           = var.subnet_id
  private_dns_zone_id           = local.private_dns_zone_id
  public_network_access_enabled = false
  administrator_login           = local.use_entra_auth ? null : var.metastore_admin_username
  administrator_password        = var.metastore_admin_password
  sku_name                      = var.metastore_sku_name
  storage_mb                    = var.metastore_storage_mb
  backup_retention_days         = var.metastore_backup_retention_days
  tags                          = merge(var.tags, { module = "smithdb" })

  authentication {
    active_directory_auth_enabled = local.use_entra_auth
    password_auth_enabled         = !local.use_entra_auth
    tenant_id                     = local.use_entra_auth ? data.azurerm_client_config.current.tenant_id : null
  }

  depends_on = [azurerm_private_dns_zone_virtual_network_link.smithdb]

}

resource "azurerm_postgresql_flexible_server_database" "metastore" {
  name      = "smithdb"
  server_id = azurerm_postgresql_flexible_server.metastore.id
  charset   = "UTF8"
  collation = "en_US.utf8"
}

resource "azurerm_user_assigned_identity" "smithdb" {
  name                = "${var.name}-identity"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = merge(var.tags, { module = "smithdb" })
}

resource "azurerm_postgresql_flexible_server_active_directory_administrator" "smithdb" {
  count = local.use_entra_auth ? 1 : 0

  server_name         = azurerm_postgresql_flexible_server.metastore.name
  resource_group_name = var.resource_group_name
  tenant_id           = data.azurerm_client_config.current.tenant_id
  object_id           = azurerm_user_assigned_identity.smithdb.principal_id
  principal_name      = azurerm_user_assigned_identity.smithdb.name
  principal_type      = "ServicePrincipal"
}

resource "azurerm_federated_identity_credential" "smithdb" {
  name                = "${var.name}-federated"
  resource_group_name = var.resource_group_name
  parent_id           = azurerm_user_assigned_identity.smithdb.id
  issuer              = var.oidc_issuer_url
  subject             = "system:serviceaccount:${var.namespace}:${var.service_account_name}"
  audience            = ["api://AzureADTokenExchange"]
}

resource "azurerm_storage_account" "smithdb" {
  name                            = var.storage_account_name
  resource_group_name             = var.resource_group_name
  location                        = var.location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  public_network_access_enabled   = true
  shared_access_key_enabled       = false
  min_tls_version                 = "TLS1_2"
  allow_nested_items_to_be_public = false
  tags                            = merge(var.tags, { module = "smithdb" })

  network_rules {
    default_action             = "Deny"
    bypass                     = ["AzureServices"]
    virtual_network_subnet_ids = [var.aks_subnet_id]
  }
}

resource "azurerm_storage_container" "smithdb" {
  name                  = var.container_name
  storage_account_id    = azurerm_storage_account.smithdb.id
  container_access_type = "private"
}

resource "azurerm_role_assignment" "smithdb_storage" {
  principal_id         = azurerm_user_assigned_identity.smithdb.principal_id
  principal_type       = "ServicePrincipal"
  role_definition_name = "Storage Blob Data Contributor"
  scope                = azurerm_storage_account.smithdb.id
}
