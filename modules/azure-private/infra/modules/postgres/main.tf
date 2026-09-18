# ══════════════════════════════════════════════════════════════════════════════
# Module: postgres
# Purpose: Azure PostgreSQL Flexible Server for LangSmith — private access only.
#
# Key design decisions:
#   • Flexible Server (not Single Server): better performance, more configuration
#     options, and is the current Azure standard.
#   • public_network_access_enabled = false: database is ONLY reachable via the
#     private endpoint — no internet exposure.
#   • Private Endpoint (not VNet injection): PE is compatible with
#     userDefinedRouting (UDR / 0.0.0.0/0 → firewall) egress, which VNet
#     injection (delegated_subnet_id) is not. The PE drops a private NIC in any
#     regular subnet; no delegation required.
#   • Private DNS zone: resolves <server>.postgres.database.azure.com to the
#     PE private IP via the dns_zone_group auto-registration.
#   • Required extensions pre-enabled: LangSmith's backend needs PGCRYPTO
#     (hashing), BTREE_GIN/PG_TRGM/BTREE_GIST (text search indexes), CITEXT
#     (case-insensitive text). These must be allow-listed before first use.
# ══════════════════════════════════════════════════════════════════════════════

# PostgreSQL Flexible Server — the primary relational database for LangSmith.
# Stores: runs, traces, feedback, users, orgs, API keys, workspace config.
#
# Default SKU: GP_Standard_D2ds_v4 = 2 vCPU, 8 GB RAM (General Purpose).
# Upgrade to GP_Standard_D4ds_v4 (4 vCPU, 16 GB) for production workloads.
resource "azurerm_postgresql_flexible_server" "db" {
  name                = var.name
  resource_group_name = var.resource_group_name
  location            = var.location
  version             = var.postgres_version

  storage_mb   = var.storage_mb   # default 32 GB; auto-grow not enabled — size upfront
  storage_tier = var.storage_tier # P4 = premium SSD, consistent IOPS
  sku_name     = var.sku_name

  administrator_login    = var.admin_username
  administrator_password = var.admin_password

  # Private Endpoint mode (not VNet injection). No delegated_subnet_id and no
  # private_dns_zone_id here — those select VNet integration, which is mutually
  # exclusive with a private endpoint and is unsupported with UDR (0.0.0.0/0 ->
  # firewall) egress. Reachability is provided by the private endpoint below.
  public_network_access_enabled = false

  zone                         = var.availability_zone
  geo_redundant_backup_enabled = var.geo_redundant_backup_enabled

  dynamic "high_availability" {
    for_each = var.standby_availability_zone != "" ? [1] : []
    content {
      mode                      = "ZoneRedundant"
      standby_availability_zone = var.standby_availability_zone
    }
  }

  tags = merge(var.tags, { module = "postgres" })

  lifecycle {
    # Azure may move the server to a different availability zone during
    # maintenance. Ignore zone drift to prevent unnecessary plan noise.
    ignore_changes = [zone]
  }
}

# LangSmith application database.
# Azure Flexible Server does not auto-create application databases — only
# the 'postgres' system database exists by default. LangSmith requires
# a database named after var.database_name to exist before the backend
# can connect.
resource "azurerm_postgresql_flexible_server_database" "langsmith" {
  name      = var.database_name
  server_id = azurerm_postgresql_flexible_server.db.id
  charset   = "UTF8"
  collation = "en_US.utf8"
}

# Private DNS zone for PostgreSQL name resolution within the VNet.
# Resolves: <server-name>.postgres.database.azure.com → private IP.
# Without this zone, AKS pods cannot resolve the database hostname.
resource "azurerm_private_dns_zone" "db_dns_zone" {
  name                = "privatelink.postgres.database.azure.com"
  resource_group_name = var.resource_group_name
  tags                = merge(var.tags, { module = "postgres" })
}

# Link the private DNS zone to the VNet so that all resources in the VNet
# (including AKS pods) can resolve the PostgreSQL private hostname.
# registration_enabled = false: we don't want auto-registration of VM names.
resource "azurerm_private_dns_zone_virtual_network_link" "dns_zone_vnet_link" {
  name                  = "${var.name}-link"
  resource_group_name   = var.resource_group_name
  private_dns_zone_name = azurerm_private_dns_zone.db_dns_zone.name
  virtual_network_id    = var.vnet_id
  registration_enabled  = false
  tags                  = merge(var.tags, { module = "postgres" })
}

# Private Endpoint into the BYO postgres subnet — gives VNet-only reachability
# without VNet injection. The endpoint's A record is auto-registered in the
# privatelink zone via the dns_zone_group, so <name>.postgres.database.azure.com
# resolves to the PE private IP for any VNet linked to the zone.
resource "azurerm_private_endpoint" "db" {
  name                = "${var.name}-pe"
  location            = var.location
  resource_group_name = var.resource_group_name
  subnet_id           = var.subnet_id

  private_service_connection {
    name                           = "${var.name}-psc"
    private_connection_resource_id = azurerm_postgresql_flexible_server.db.id
    subresource_names              = ["postgresqlServer"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "postgres"
    private_dns_zone_ids = [azurerm_private_dns_zone.db_dns_zone.id]
  }

  tags = merge(var.tags, { module = "postgres" })
}

# Allow-list PostgreSQL extensions that LangSmith requires.
# These must be enabled at the server level before any extension can be
# created inside the database with CREATE EXTENSION.
#   PGCRYPTO   — password/token hashing (gen_random_bytes, crypt)
#   BTREE_GIN  — GIN indexes on btree-compatible columns (multi-column search)
#   PG_TRGM    — trigram-based fuzzy text search (run/trace name search)
#   BTREE_GIST — GiST indexes for range queries
#   CITEXT     — case-insensitive text type (email lookups)
resource "azurerm_postgresql_flexible_server_configuration" "extensions" {
  name      = "azure.extensions"
  server_id = azurerm_postgresql_flexible_server.db.id
  value     = "PGCRYPTO,BTREE_GIN,PG_TRGM,BTREE_GIST,CITEXT"
}

# Increase max_connections from the default (which scales with RAM).
# LangSmith runs multiple services (backend, platform-backend, queue) each
# maintaining a connection pool. Default is often too low under load.
resource "azurerm_postgresql_flexible_server_configuration" "max_connections" {
  name      = "max_connections"
  server_id = azurerm_postgresql_flexible_server.db.id
  value     = var.max_connections

  # Flexible Server serializes configuration operations — applying this in
  # parallel with the azure.extensions update races and fails the second one
  # with "ServerIsBusy" on a first apply. Serialize them so one finishes before
  # the next starts.
  depends_on = [azurerm_postgresql_flexible_server_configuration.extensions]
}
