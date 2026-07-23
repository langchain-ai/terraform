# ══════════════════════════════════════════════════════════════════════════════
# TEST SCAFFOLD — hub-and-spoke + Azure Firewall (Basic) + jumpbox apply host.
#
# Purpose: stand up the prerequisite network that modules/azure-private CONSUMES,
# so you can test a real private-cluster deployment. This is NOT part of a
# production deployment — apply it, feed its outputs into azure-private, run the
# module from the jumpbox, then `terraform destroy` it.
#
# Deploys into an EXISTING resource group (var.resource_group_name); region is
# inherited from that RG. Destroy removes only the scaffold's resources — never
# the RG itself.
#
# Topology:
#   Hub  10.0.0.0/16  — AzureFirewallSubnet (+ mgmt subnet) + Azure Firewall Basic
#   Spoke 10.1.0.0/16 — aks / postgres-pe / redis-pe / jumpbox subnets
#   Peering hub <-> spoke; AKS subnet default-routes 0.0.0.0/0 -> firewall.
# ══════════════════════════════════════════════════════════════════════════════

locals {
  # Subnet plan.
  fw_subnet_cidr      = cidrsubnet(var.hub_cidr, 10, 0) # 10.0.0.0/26  (AzureFirewallSubnet, /26 min)
  fw_mgmt_subnet_cidr = cidrsubnet(var.hub_cidr, 10, 1) # 10.0.0.64/26 (AzureFirewallManagementSubnet)

  aks_subnet_cidr      = cidrsubnet(var.spoke_cidr, 6, 0) # 10.1.0.0/22  (nodes; pods use overlay pod_cidr)
  postgres_subnet_cidr = cidrsubnet(var.spoke_cidr, 8, 4) # 10.1.4.0/24  (Postgres private endpoint)
  redis_subnet_cidr    = cidrsubnet(var.spoke_cidr, 8, 5) # 10.1.5.0/24  (Redis private endpoint)
  jumpbox_subnet_cidr  = cidrsubnet(var.spoke_cidr, 8, 6) # 10.1.6.0/24  (jumpbox apply host)

  location = data.azurerm_resource_group.test.location
}

# Existing resource group — everything in this scaffold deploys here. The scaffold
# never creates or deletes the RG; `terraform destroy` removes only its resources.
data "azurerm_resource_group" "test" {
  name = var.resource_group_name
}

# ── Hub VNet + Azure Firewall (Basic) ─────────────────────────────────────────

resource "azurerm_virtual_network" "hub" {
  name                = "${var.prefix}-hub-vnet"
  location            = local.location
  resource_group_name = data.azurerm_resource_group.test.name
  address_space       = [var.hub_cidr]
  tags                = var.tags
}

# Azure Firewall requires a subnet named EXACTLY "AzureFirewallSubnet".
resource "azurerm_subnet" "firewall" {
  name                 = "AzureFirewallSubnet"
  resource_group_name  = data.azurerm_resource_group.test.name
  virtual_network_name = azurerm_virtual_network.hub.name
  address_prefixes     = [local.fw_subnet_cidr]
}

# Firewall Basic SKU additionally requires "AzureFirewallManagementSubnet".
resource "azurerm_subnet" "firewall_mgmt" {
  name                 = "AzureFirewallManagementSubnet"
  resource_group_name  = data.azurerm_resource_group.test.name
  virtual_network_name = azurerm_virtual_network.hub.name
  address_prefixes     = [local.fw_mgmt_subnet_cidr]
}

resource "azurerm_public_ip" "fw_data" {
  name                = "${var.prefix}-fw-data-pip"
  location            = local.location
  resource_group_name = data.azurerm_resource_group.test.name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

# Basic SKU mandates a separate management public IP.
resource "azurerm_public_ip" "fw_mgmt" {
  name                = "${var.prefix}-fw-mgmt-pip"
  location            = local.location
  resource_group_name = data.azurerm_resource_group.test.name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

resource "azurerm_firewall_policy" "hub" {
  name                = "${var.prefix}-fw-policy"
  resource_group_name = data.azurerm_resource_group.test.name
  location            = local.location
  sku                 = "Basic"
  tags                = var.tags
}

# Minimal AKS egress allowlist (per "Control egress traffic for AKS"):
#   • Application rule: the AzureKubernetesService FQDN tag (control-plane, image
#     pulls, etc. over 80/443).
#   • Network rules: API server tunnel (UDP 1194 / TCP 9000 to AzureCloud) + NTP.
resource "azurerm_firewall_policy_rule_collection_group" "aks_egress" {
  name               = "aks-egress"
  firewall_policy_id = azurerm_firewall_policy.hub.id
  priority           = 200

  application_rule_collection {
    name     = "aks-application"
    priority = 200
    action   = "Allow"

    rule {
      name                  = "aks-fqdn-tag"
      source_addresses      = [var.spoke_cidr]
      destination_fqdn_tags = ["AzureKubernetesService"]
      protocols {
        type = "Http"
        port = 80
      }
      protocols {
        type = "Https"
        port = 443
      }
    }
  }

  network_rule_collection {
    name     = "aks-network"
    priority = 210
    action   = "Allow"

    rule {
      name                  = "apiserver-udp"
      protocols             = ["UDP"]
      source_addresses      = [var.spoke_cidr]
      destination_addresses = ["AzureCloud"]
      destination_ports     = ["1194"]
    }
    rule {
      name                  = "apiserver-tcp"
      protocols             = ["TCP"]
      source_addresses      = [var.spoke_cidr]
      destination_addresses = ["AzureCloud"]
      destination_ports     = ["9000"]
    }
    rule {
      name                  = "ntp"
      protocols             = ["UDP"]
      source_addresses      = [var.spoke_cidr]
      destination_addresses = ["*"]
      destination_ports     = ["123"]
    }
  }
}

resource "azurerm_firewall" "hub" {
  name                = "${var.prefix}-fw"
  location            = local.location
  resource_group_name = data.azurerm_resource_group.test.name
  sku_name            = "AZFW_VNet"
  sku_tier            = "Basic"
  firewall_policy_id  = azurerm_firewall_policy.hub.id
  tags                = var.tags

  ip_configuration {
    name                 = "data"
    subnet_id            = azurerm_subnet.firewall.id
    public_ip_address_id = azurerm_public_ip.fw_data.id
  }

  management_ip_configuration {
    name                 = "management"
    subnet_id            = azurerm_subnet.firewall_mgmt.id
    public_ip_address_id = azurerm_public_ip.fw_mgmt.id
  }
}

# ── Spoke VNet + subnets ──────────────────────────────────────────────────────

resource "azurerm_virtual_network" "spoke" {
  name                = "${var.prefix}-spoke-vnet"
  location            = local.location
  resource_group_name = data.azurerm_resource_group.test.name
  address_space       = [var.spoke_cidr]
  tags                = var.tags
}

# AKS node subnet — service endpoints let the Blob/Key Vault default-deny
# firewalls allowlist this subnet (azure-private requires both).
resource "azurerm_subnet" "aks" {
  name                 = "aks"
  resource_group_name  = data.azurerm_resource_group.test.name
  virtual_network_name = azurerm_virtual_network.spoke.name
  address_prefixes     = [local.aks_subnet_cidr]
  service_endpoints    = ["Microsoft.Storage", "Microsoft.KeyVault"]
}

# Postgres private-endpoint subnet (regular subnet, NOT delegated).
resource "azurerm_subnet" "postgres" {
  name                 = "postgres-pe"
  resource_group_name  = data.azurerm_resource_group.test.name
  virtual_network_name = azurerm_virtual_network.spoke.name
  address_prefixes     = [local.postgres_subnet_cidr]
}

# Redis private-endpoint subnet.
resource "azurerm_subnet" "redis" {
  name                 = "redis-pe"
  resource_group_name  = data.azurerm_resource_group.test.name
  virtual_network_name = azurerm_virtual_network.spoke.name
  address_prefixes     = [local.redis_subnet_cidr]
}

# Jumpbox subnet (apply host + azure-private's own bastion both land here).
resource "azurerm_subnet" "jumpbox" {
  name                 = "jumpbox"
  resource_group_name  = data.azurerm_resource_group.test.name
  virtual_network_name = azurerm_virtual_network.spoke.name
  address_prefixes     = [local.jumpbox_subnet_cidr]
}

# ── UDR: default-route the AKS subnet through the firewall ─────────────────────

resource "azurerm_route_table" "aks" {
  name                = "${var.prefix}-aks-rt"
  location            = local.location
  resource_group_name = data.azurerm_resource_group.test.name
  tags                = var.tags
}

resource "azurerm_route" "default_to_firewall" {
  name                   = "default-to-firewall"
  resource_group_name    = data.azurerm_resource_group.test.name
  route_table_name       = azurerm_route_table.aks.name
  address_prefix         = "0.0.0.0/0"
  next_hop_type          = "VirtualAppliance"
  next_hop_in_ip_address = azurerm_firewall.hub.ip_configuration[0].private_ip_address
}

resource "azurerm_subnet_route_table_association" "aks" {
  subnet_id      = azurerm_subnet.aks.id
  route_table_id = azurerm_route_table.aks.id
}

# ── Peering hub <-> spoke ─────────────────────────────────────────────────────

resource "azurerm_virtual_network_peering" "hub_to_spoke" {
  name                         = "hub-to-spoke"
  resource_group_name          = data.azurerm_resource_group.test.name
  virtual_network_name         = azurerm_virtual_network.hub.name
  remote_virtual_network_id    = azurerm_virtual_network.spoke.id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
}

resource "azurerm_virtual_network_peering" "spoke_to_hub" {
  name                         = "spoke-to-hub"
  resource_group_name          = data.azurerm_resource_group.test.name
  virtual_network_name         = azurerm_virtual_network.spoke.name
  remote_virtual_network_id    = azurerm_virtual_network.hub.id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
}

# ── Jumpbox apply host ────────────────────────────────────────────────────────
# A private cluster can't be bootstrapped from your laptop. SSH here (it lands in
# the spoke), install/clone azure-private, and run `terraform apply` from this VM.

# Gated by var.create_jumpbox. The jumpbox SUBNET stays regardless (azure-private's
# own bastion uses it as bastion_subnet_id) — only the VM + its NIC/NSG/PIP are
# optional. Skip it for an infra-only test (the apply runs from outside the VNet).
resource "azurerm_public_ip" "jumpbox" {
  count               = var.create_jumpbox ? 1 : 0
  name                = "${var.prefix}-jumpbox-pip"
  location            = local.location
  resource_group_name = data.azurerm_resource_group.test.name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

resource "azurerm_network_security_group" "jumpbox" {
  count               = var.create_jumpbox ? 1 : 0
  name                = "${var.prefix}-jumpbox-nsg"
  location            = local.location
  resource_group_name = data.azurerm_resource_group.test.name
  tags                = var.tags

  security_rule {
    name                       = "allow-ssh-from-operator"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = var.allowed_ssh_cidr
    destination_address_prefix = "*"
  }

  # Enforce the SSH source restriction only when the jumpbox exists (a counted
  # resource's precondition is not evaluated when count = 0).
  lifecycle {
    precondition {
      condition     = var.allowed_ssh_cidr != "" && var.allowed_ssh_cidr != "0.0.0.0/0"
      error_message = "allowed_ssh_cidr must be a specific CIDR (e.g. your IP /32) when create_jumpbox = true; empty or 0.0.0.0/0 is not allowed."
    }
  }
}

resource "azurerm_network_interface" "jumpbox" {
  count               = var.create_jumpbox ? 1 : 0
  name                = "${var.prefix}-jumpbox-nic"
  location            = local.location
  resource_group_name = data.azurerm_resource_group.test.name
  tags                = var.tags

  ip_configuration {
    name                          = "ipconfig"
    subnet_id                     = azurerm_subnet.jumpbox.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.jumpbox[0].id
  }
}

resource "azurerm_network_interface_security_group_association" "jumpbox" {
  count                     = var.create_jumpbox ? 1 : 0
  network_interface_id      = azurerm_network_interface.jumpbox[0].id
  network_security_group_id = azurerm_network_security_group.jumpbox[0].id
}

resource "azurerm_linux_virtual_machine" "jumpbox" {
  count                 = var.create_jumpbox ? 1 : 0
  name                  = "${var.prefix}-jumpbox"
  location              = local.location
  resource_group_name   = data.azurerm_resource_group.test.name
  size                  = var.jumpbox_vm_size
  admin_username        = var.jumpbox_admin_username
  network_interface_ids = [azurerm_network_interface.jumpbox[0].id]
  tags                  = var.tags

  # Key auth only — providing admin_ssh_key with no admin_password disables
  # password authentication.
  admin_ssh_key {
    username   = var.jumpbox_admin_username
    public_key = var.jumpbox_ssh_public_key
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }

  # Installs az / terraform / kubectl / helm so you can run azure-private here.
  custom_data = base64encode(file("${path.module}/cloud-init.yaml"))
}
