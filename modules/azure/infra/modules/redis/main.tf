# ══════════════════════════════════════════════════════════════════════════════
# Module: redis
# Purpose: Azure Managed Redis (AMR) for LangSmith — private access only.
#
# Replaces classic Azure Cache for Redis (azurerm_redis_cache), which is retiring
# ("Creation of new Azure Cache for Redis Enterprise resources is no longer
# supported"). AMR = Microsoft.Cache/redisEnterprise, provisioned via azapi because
# the Balanced_* SKUs aren't reliably exposed by the azurerm provider yet.
#
# Networking parity with the old classic module ("private access only"):
#   classic used VNet subnet INJECTION; AMR doesn't support that, so the private
#   equivalent is a Private Endpoint into the same redis subnet + a private DNS zone.
#
# Connection: TLS on port 10000. Client mode follows var.clustering_policy — OSSCluster
# needs the cluster client, EnterpriseCluster the standalone client with clusterSafeMode.
# Mismatched, every usage-limit check fails on MOVED and the ingest path returns 503.
# ══════════════════════════════════════════════════════════════════════════════

locals {
  private_dns_zone_id = var.create_private_dns_zone ? azurerm_private_dns_zone.redis[0].id : var.private_dns_zone_id
}

# AMR cluster — Balanced SKU, TLS 1.2, no public access (private endpoint only).
resource "azapi_resource" "amr" {
  type      = "Microsoft.Cache/redisEnterprise@2025-07-01"
  name      = var.name
  location  = coalesce(var.cluster_location, var.location)
  parent_id = var.resource_group_id

  body = {
    sku = { name = var.amr_sku }
    properties = {
      minimumTlsVersion = "1.2"
      # Required at API 2025-07-01. Private-endpoint-only — no public access.
      publicNetworkAccess = "Disabled"
      # HA (zone redundancy) is unsupported on the smallest (B0) SKU.
      highAvailability = var.high_availability ? "Enabled" : "Disabled"
    }
  }

  response_export_values = ["properties.hostName"]
  tags                   = merge(var.tags, { module = "redis" })

  # azapi's bundled schema lags behind AMR (Balanced SKU / highAvailability).
  # The body matches what `az redisenterprise create` accepts — let ARM validate at apply.
  schema_validation_enabled = false
}

# AMR database — clustering policy per var, TLS (Encrypted) on port 10000, key auth on.
resource "azapi_resource" "amr_db" {
  type      = "Microsoft.Cache/redisEnterprise/databases@2025-07-01"
  name      = "default"
  parent_id = azapi_resource.amr.id

  # evictionPolicy is sent only when set, so an existing database's body, and
  # the plan for it, stay unchanged. Azure's default is VolatileLRU.
  body = {
    properties = merge({
      clientProtocol           = "Encrypted"
      port                     = 10000
      clusteringPolicy         = var.clustering_policy
      accessKeysAuthentication = "Enabled"
    }, var.eviction_policy == null ? {} : { evictionPolicy = var.eviction_policy })
  }

  schema_validation_enabled = false
}

# Primary access key — used to build the connection URL.
resource "azapi_resource_action" "amr_keys" {
  type        = "Microsoft.Cache/redisEnterprise/databases@2025-07-01"
  resource_id = azapi_resource.amr_db.id
  action      = "listKeys"

  response_export_values = ["primaryKey"]
}

# ── Private access (parity with classic's "private only") ─────────────────────
# AMR can't inject into a subnet, so a Private Endpoint in the same redis subnet +
# a private DNS zone give equivalent VNet-only reachability. The endpoint hostname
# (*.redis.azure.net) resolves to the PE's private IP via this zone.
#
# A second AMR in the same resource group sets create_private_dns_zone = false
# and passes the first one's zone in private_dns_zone_id: the zone name is
# fixed, so a second copy would collide. The flag, not the ID, drives count,
# because the first zone's ID is unknown until it exists.
# Adding count moves an existing zone and link to index [0] with no replacement.
resource "azurerm_private_dns_zone" "redis" {
  count               = var.create_private_dns_zone ? 1 : 0
  name                = "privatelink.redis.azure.net"
  resource_group_name = var.resource_group_name
  tags                = merge(var.tags, { module = "redis" })
}

resource "azurerm_private_dns_zone_virtual_network_link" "redis" {
  count                 = var.create_private_dns_zone ? 1 : 0
  name                  = "${var.name}-dnslink"
  resource_group_name   = var.resource_group_name
  private_dns_zone_name = azurerm_private_dns_zone.redis[0].name
  virtual_network_id    = var.vnet_id
  tags                  = merge(var.tags, { module = "redis" })
}

resource "azurerm_private_endpoint" "redis" {
  name                = "${var.name}-pe"
  location            = var.location
  resource_group_name = var.resource_group_name
  subnet_id           = var.subnet_id

  private_service_connection {
    name                           = "${var.name}-psc"
    private_connection_resource_id = azapi_resource.amr.id
    subresource_names              = ["redisEnterprise"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "redis"
    private_dns_zone_ids = [local.private_dns_zone_id]
  }

  tags = merge(var.tags, { module = "redis" })
}
