# ══════════════════════════════════════════════════════════════════════════════
# Module: redis
# Purpose: Azure Redis Cache (Premium) for LangSmith — private access only.
#
# LangSmith uses Redis for:
#   • Run/trace ingestion queues (async processing pipeline)
#   • Pub/sub for real-time streaming responses (SSE to frontend)
#   • Short-lived caching of API responses and session state
#   • KEDA queue-depth scaling: KEDA reads queue lengths to scale workers
#
# Why Premium SKU?
#   • Only Premium supports VNet injection (subnet_id).
#   • Premium provides persistence, geo-replication, and clustering (future).
#   • Capacity 2 = P2 = 13 GB RAM — adequate for moderate LangSmith workloads.
#     Scale to capacity 3 (P3, 26 GB) for heavy trace ingestion.
#
# Connection: rediss://:primary_access_key@host:6380  (TLS port 6380)
# ══════════════════════════════════════════════════════════════════════════════

# Azure Redis Cache — Premium tier with VNet injection.
# public_network_access_enabled = false ensures Redis is only reachable
# from within the VNet; no internet exposure even if firewall rules exist.
# TLS is enforced on port 6380 (non-TLS port 6379 is disabled by default
# on Premium). The connection URL in outputs uses rediss:// (TLS scheme).
resource "azurerm_redis_cache" "redis" {
  name                = var.name
  location            = var.location
  resource_group_name = var.resource_group_name

  # Premium P-family: capacity maps to P1=6GB, P2=13GB, P3=26GB, P4=53GB
  capacity = var.capacity # default: 2 (P2, 13 GB)
  family   = var.family   # "P" = Premium (required for VNet injection)
  sku_name = var.sku_name # "Premium"

  # Inject Redis into its dedicated subnet (Premium requirement).
  # The subnet must be exclusive to Redis — no other resources allowed.
  subnet_id = var.subnet_id

  # Disable public access: all connections must originate within the VNet.
  public_network_access_enabled = false

  tags = merge(var.tags, { module = "redis" })
}
