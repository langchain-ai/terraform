# ══════════════════════════════════════════════════════════════════════════════
# Module: postgres
# Purpose: Azure PostgreSQL Flexible Server for LangSmith — private access only.
#
# Key design decisions:
#   • Flexible Server (not Single Server): supports VNet injection, better
#     performance, more configuration options, and is the current Azure standard.
#   • public_network_access_enabled = false: database is ONLY reachable from
#     within the VNet via private IP — no internet exposure.
#   • Private DNS zone: resolves <server>.postgres.database.azure.com to the
#     private IP. Without this, pods cannot resolve the hostname.
#   • Delegated subnet: Azure injects the server NIC into the Postgres subnet;
#     no other resources can share that subnet.
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

  # Private-only: no public endpoint. Access via private DNS + VNet only.
  public_network_access_enabled = false
  delegated_subnet_id           = var.subnet_id
  private_dns_zone_id           = azurerm_private_dns_zone.db_dns_zone.id

  tags = merge(var.tags, { module = "postgres" })

  lifecycle {
    # Azure may move the server to a different availability zone during
    # maintenance. Ignore zone drift to prevent unnecessary plan noise.
    ignore_changes = [zone]
  }
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
}
