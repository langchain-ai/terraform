resource "azurerm_virtual_network" "vnet" {
  name                = var.network_name
  address_space       = var.address_space
  location            = var.location
  resource_group_name = var.resource_group_name
}

# Main subnet for all resources
resource "azurerm_subnet" "subnet_main" {
  name                 = "${var.network_name}-subnet-0"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = var.main_subnet_address_prefix
}

# Independent subnet for Postgres
resource "azurerm_subnet" "subnet_postgres" {
  count = var.enable_external_postgres ? 1 : 0
  name                 = "${var.network_name}-subnet-postgres"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.32.0/20"]  # 4k IP addresses

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

# Independent subnet for Redis
resource "azurerm_subnet" "subnet_redis" {
  count = var.enable_external_redis ? 1 : 0
  name                 = "${var.cluster_name}-subnet-redis"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.48.0/20"]  # 4k IP addresses
}
