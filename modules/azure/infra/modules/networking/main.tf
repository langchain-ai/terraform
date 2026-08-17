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
#
# Bring-your-own network:
#   create_vnet = false skips the VNet and creates the subnets inside the VNet
#   named by existing_vnet_id instead. Each subnet is independently opt-out via
#   its create_*_subnet flag, so an operator can supply some subnet IDs and let
#   Terraform carve the rest. With every flag false this module creates nothing.
# ══════════════════════════════════════════════════════════════════════════════

locals {
  # An existing VNet lives in its own resource group, which is not necessarily
  # the LangSmith resource group, so subnets must be placed by parsing the ID.
  # Azure VNet IDs are fixed-shape, so index positionally rather than matching
  # on segment names (Azure is inconsistent about "resourceGroups" casing):
  #   0:"" 1:subscriptions 2:<sub> 3:resourceGroups 4:<rg>
  #   5:providers 6:Microsoft.Network 7:virtualNetworks 8:<name>
  # The root module validates the shape before this ever runs; the length guard
  # keeps the empty-string default (create_vnet = true) from erroring here.
  existing_vnet_parts = split("/", var.existing_vnet_id)
  existing_vnet_valid = length(local.existing_vnet_parts) == 9

  # Where every subnet below gets created.
  subnet_resource_group_name = var.create_vnet ? var.resource_group_name : (local.existing_vnet_valid ? local.existing_vnet_parts[4] : "")
  subnet_vnet_name           = var.create_vnet ? one(azurerm_virtual_network.vnet[*].name) : (local.existing_vnet_valid ? local.existing_vnet_parts[8] : "")
}

# The top-level VNet that all LangSmith resources share.
# Azure CNI places AKS node & pod IPs directly in the subnet address space,
# so the main subnet must be large enough for max_nodes * max_pods_per_node.
resource "azurerm_virtual_network" "vnet" {
  count               = var.create_vnet ? 1 : 0
  name                = var.network_name
  address_space       = var.address_space
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = merge(var.tags, { module = "vnet" })
}

# Main subnet — used by AKS nodes and pods (Azure CNI).
# With Standard_D4_v5 nodes (30 max pods each) and up to 10 nodes,
# you need at least 300 IPs. /19 = 8 192 IPs — plenty of headroom.
#
# service_endpoints: enabling Microsoft.Storage and Microsoft.KeyVault on the
# AKS subnet lets the storage account and key vault default-deny firewalls
# allowlist this subnet directly (via virtual_network_subnet_ids). Without the
# endpoints the data-plane traffic from pods would be NAT'd to a public IP and
# blocked by the deny rule. Cheap to enable and required for the storage/KV
# default-deny posture in modules/storage and modules/keyvault.
resource "azurerm_subnet" "subnet_main" {
  count                = var.create_main_subnet ? 1 : 0
  name                 = "${var.network_name}-subnet-0"
  resource_group_name  = local.subnet_resource_group_name
  virtual_network_name = local.subnet_vnet_name
  address_prefixes     = var.main_subnet_address_prefix
  service_endpoints    = ["Microsoft.Storage", "Microsoft.KeyVault"]
}

# PostgreSQL subnet — created only when create_postgres_subnet = true.
# MUST be delegated to Microsoft.DBforPostgreSQL/flexibleServers; the
# delegation grants the service permission to inject NICs into this subnet.
# No other resources can be placed in a delegated subnet.
# An operator-supplied Postgres subnet must already carry this delegation —
# the root module verifies that at plan time before the server is created.
resource "azurerm_subnet" "subnet_postgres" {
  count                = var.create_postgres_subnet ? 1 : 0
  name                 = "${var.network_name}-subnet-postgres"
  resource_group_name  = local.subnet_resource_group_name
  virtual_network_name = local.subnet_vnet_name
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

# Redis subnet — created only when create_redis_subnet = true.
# Deliberately NOT delegated. Azure Managed Redis is not subnet-injected; the
# redis module reaches it through a private endpoint placed in this subnet
# (see modules/redis/main.tf). A delegation here would in fact block that,
# since a delegated subnet accepts only its delegated service.
resource "azurerm_subnet" "subnet_redis" {
  count                = var.create_redis_subnet ? 1 : 0
  name                 = "${var.network_name}-subnet-redis"
  resource_group_name  = local.subnet_resource_group_name
  virtual_network_name = local.subnet_vnet_name
  address_prefixes     = var.redis_subnet_address_prefix
}

# Bastion subnet — dedicated /27 for the jump VM (Azure Bastion also uses this name convention).
# Created only when enable_bastion = true.
resource "azurerm_subnet" "subnet_bastion" {
  count                = var.enable_bastion ? 1 : 0
  name                 = "${var.network_name}-subnet-bastion"
  resource_group_name  = local.subnet_resource_group_name
  virtual_network_name = local.subnet_vnet_name
  address_prefixes     = var.bastion_subnet_address_prefix
}

# Application Gateway subnet — required when ingress_controller = "agic".
# Azure Application Gateway v2 requires an exclusive subnet of at least /24.
# No other resources (pods, VMs) may be placed in this subnet.
#
# Delegated to Microsoft.Network/applicationGateways. Azure applies network
# isolation to new v2 gateways, and an isolated gateway is rejected outright in a
# subnet that carries no delegation:
#
#   ApplicationGatewayNetworkIsolationRequiresSubnetDelegation: Application
#   Gateway <id> with NetworkIsolation requires subnet delegation.
#
# The gateway is the only thing this module puts in the subnet, so delegating it
# to the service costs nothing that was available before.
resource "azurerm_subnet" "subnet_agic" {
  count                = var.enable_agic ? 1 : 0
  name                 = "${var.network_name}-subnet-agic"
  resource_group_name  = local.subnet_resource_group_name
  virtual_network_name = local.subnet_vnet_name
  address_prefixes     = var.agic_subnet_address_prefix

  delegation {
    name = "appgw-delegation"

    service_delegation {
      name = "Microsoft.Network/applicationGateways"

      actions = [
        "Microsoft.Network/virtualNetworks/subnets/join/action",
      ]
    }
  }
}
