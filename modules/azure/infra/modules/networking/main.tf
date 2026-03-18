# ══════════════════════════════════════════════════════════════════════════════
# Module: vnet
# Purpose: Azure Virtual Network with dedicated subnets for each service tier.
#
# Network layout (defaults):
#   VNet          10.0.0.0/17   — overall address space (32 k IPs)
#   AKS subnet    10.0.0.0/19   — node & pod IPs (Azure CNI, 8 k IPs)
#   Postgres      10.0.32.0/20  — delegated to PostgreSQL Flexible Server (4 k IPs)
#   Redis         10.0.48.0/20  — Premium Redis requires a dedicated subnet (4 k IPs)
#   K8s svc CIDR  10.0.64.0/20  — defined in AKS module, must NOT overlap VNet ranges
#
# Why dedicated subnets?
#   • PostgreSQL Flexible Server requires its own delegated subnet (Azure restriction).
#   • Redis Premium requires its own dedicated subnet.
#   • Isolation allows independent NSG rules per service tier in Stage 3.
# ══════════════════════════════════════════════════════════════════════════════

# The top-level VNet that all LangSmith resources share.
# Azure CNI places AKS node & pod IPs directly in the subnet address space,
# so the main subnet must be large enough for max_nodes * max_pods_per_node.
resource "azurerm_virtual_network" "vnet" {
  name                = var.network_name
  address_space       = var.address_space
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = merge(var.tags, { module = "vnet" })
}

# Main subnet — used by AKS nodes and pods (Azure CNI).
# With Standard_D4_v5 nodes (30 max pods each) and up to 10 nodes,
# you need at least 300 IPs. /19 = 8 192 IPs — plenty of headroom.
resource "azurerm_subnet" "subnet_main" {
  name                 = "${var.network_name}-subnet-0"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = var.main_subnet_address_prefix
}

# PostgreSQL subnet — created only when enable_external_postgres = true.
# MUST be delegated to Microsoft.DBforPostgreSQL/flexibleServers; the
# delegation grants the service permission to inject NICs into this subnet.
# No other resources can be placed in a delegated subnet.
resource "azurerm_subnet" "subnet_postgres" {
  count                = var.enable_external_postgres ? 1 : 0
  name                 = "${var.network_name}-subnet-postgres"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = var.postgres_subnet_address_prefix

  delegation {
    name = "postgresql-delegation"

    service_delegation {
      name = "Microsoft.DBforPostgreSQL/flexibleServers"

      actions = [
        "Microsoft.Network/virtualNetworks/subnets/join/action",
      ]
    }
  }
}

# Redis subnet — created only when enable_external_redis = true.
# Azure Redis Cache Premium tier requires an exclusive subnet
# (no other resources allowed). Must be /28 or larger.
resource "azurerm_subnet" "subnet_redis" {
  count                = var.enable_external_redis ? 1 : 0
  name                 = "${var.network_name}-subnet-redis"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = var.redis_subnet_address_prefix
}
