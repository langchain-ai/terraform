# ══════════════════════════════════════════════════════════════════════════════
# Module: vnet
# Purpose: Azure Virtual Network with dedicated subnets for each service tier.
#
# Network layout (defaults):
#   VNet          10.0.0.0/17   — overall address space (32 k IPs)
#   AKS subnet    10.0.0.0/19   — node IPs, plus pod IPs in node-subnet mode (8 k IPs)
#   Postgres      10.0.32.0/20  — delegated to PostgreSQL Flexible Server (4 k IPs)
#   Redis         10.0.48.0/20  — Premium Redis requires a dedicated subnet (4 k IPs)
#   K8s svc CIDR  10.0.64.0/20  — defined in AKS module, must NOT overlap any subnet
#
# Why dedicated subnets?
#   • PostgreSQL Flexible Server requires its own delegated subnet (Azure restriction).
#   • Redis Premium requires its own dedicated subnet.
#   • Isolation gives each tier its own NSG when enable_subnet_nsgs = true.
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
# In node-subnet mode Azure CNI places node and pod IPs in the AKS subnet, so it
# must hold max_nodes * max_pods_per_node; in overlay mode only the nodes draw
# from it and pods come from aks_pod_cidr, which is not part of the VNet.
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

  # The Postgres network-integration principal adds Microsoft.Storage here
  # itself once the server is injected. service_endpoints is Optional and not
  # Computed, so declaring nothing plans to strip it on every run.
  lifecycle {
    ignore_changes = [service_endpoints]
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

  # Azure skips NSG evaluation for private endpoint traffic unless the subnet
  # opts in, which would leave the Redis NSG below attached and inert. Disabled
  # is the provider default, so a deployment without the NSGs plans clean.
  private_endpoint_network_policies = var.enable_subnet_nsgs ? "NetworkSecurityGroupEnabled" : "Disabled"
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
# The delegation is required: Azure applies network isolation to new v2 gateways
# and rejects an isolated gateway in an undelegated subnet with
# ApplicationGatewayNetworkIsolationRequiresSubnetDelegation.
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

  # Same precaution as subnet_postgres above, though Application Gateway has
  # not been seen adding an endpoint.
  lifecycle {
    ignore_changes = [service_endpoints]
  }
}

# ── Subnet NSGs ──────────────────────────────────────────────────────────────
# Opt-in with enable_subnet_nsgs, and only on subnets this module creates: a
# supplied subnet's NSG belongs to whoever supplied it. Outbound keeps Azure's
# default rules on all three, since AKS egress is FQDN-based and an NSG cannot
# express it.
#
# Azure's defaults already deny inbound Internet and admit the whole VNet
# (AllowVnetInBound, priority 65000). The Postgres and Redis NSGs narrow that to
# the AKS node subnet with a VirtualNetwork deny at 4096. Pods reach both from
# node addresses: node-subnet mode gives pods addresses in the node subnet, and
# overlay mode translates pod addresses to the node's on the way out.

resource "azurerm_network_security_group" "aks" {
  count               = var.enable_subnet_nsgs && var.create_main_subnet ? 1 : 0
  name                = "${var.network_name}-subnet-0-nsg"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = merge(var.tags, { module = "vnet" })

  # Public ingress load balancers. AKS writes its per-service rules into the NSG
  # in the node resource group, never into a subnet NSG, so the subnet has to
  # admit the ingress ports itself or Azure drops the traffic at this hop.
  security_rule {
    name                       = "allow-ingress-http-https"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_ranges    = ["80", "443"]
    source_address_prefix      = "Internet"
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "aks" {
  count                     = length(azurerm_network_security_group.aks)
  subnet_id                 = azurerm_subnet.subnet_main[0].id
  network_security_group_id = azurerm_network_security_group.aks[0].id
}

resource "azurerm_network_security_group" "postgres" {
  count               = var.enable_subnet_nsgs && var.create_postgres_subnet ? 1 : 0
  name                = "${var.network_name}-subnet-postgres-nsg"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = merge(var.tags, { module = "vnet" })

  security_rule {
    name                       = "allow-aks-postgres"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "5432"
    source_address_prefixes    = var.aks_source_prefixes
    destination_address_prefix = "*"
  }

  # A zone-redundant HA standby replicates from the primary inside this subnet.
  security_rule {
    name                       = "allow-postgres-subnet"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefixes    = var.postgres_subnet_address_prefix
    destination_address_prefix = "*"
  }

  # The VirtualNetwork tag covers the host address 168.63.129.16, so the deny
  # below would otherwise win over Azure's own AllowAzureLoadBalancerInBound.
  security_rule {
    name                       = "allow-azure-load-balancer"
    priority                   = 4095
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "AzureLoadBalancer"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "deny-vnet-inbound"
    priority                   = 4096
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "postgres" {
  count                     = length(azurerm_network_security_group.postgres)
  subnet_id                 = azurerm_subnet.subnet_postgres[0].id
  network_security_group_id = azurerm_network_security_group.postgres[0].id
}

resource "azurerm_network_security_group" "redis" {
  count               = var.enable_subnet_nsgs && var.create_redis_subnet ? 1 : 0
  name                = "${var.network_name}-subnet-redis-nsg"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = merge(var.tags, { module = "vnet" })

  # Managed Redis listens on 10000 (TLS). OSSCluster clients then connect to
  # each shard directly on 8500-8599; EnterpriseCluster proxies everything
  # through 10000, so the range is open but unused there.
  security_rule {
    name                       = "allow-aks-redis"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_ranges    = ["10000", "8500-8599"]
    source_address_prefixes    = var.aks_source_prefixes
    destination_address_prefix = "*"
  }

  # The VirtualNetwork tag covers the host address 168.63.129.16, so the deny
  # below would otherwise win over Azure's own AllowAzureLoadBalancerInBound.
  security_rule {
    name                       = "allow-azure-load-balancer"
    priority                   = 4095
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "AzureLoadBalancer"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "deny-vnet-inbound"
    priority                   = 4096
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "redis" {
  count                     = length(azurerm_network_security_group.redis)
  subnet_id                 = azurerm_subnet.subnet_redis[0].id
  network_security_group_id = azurerm_network_security_group.redis[0].id
}
