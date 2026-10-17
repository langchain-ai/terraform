# ══════════════════════════════════════════════════════════════════════════════
# Module: bastion
# Purpose: Lightweight jump VM for private AKS cluster access.
#
# Uses Azure AD (Entra ID) SSH login — no static SSH keys needed.
# Access model: az ssh vm -n <vm-name> -g <rg> (uses az CLI identity)
# Pre-installs: kubectl, helm, azure CLI, jq, curl
#
# Equivalent to the AWS bastion EC2 module with SSM Session Manager access.
# ══════════════════════════════════════════════════════════════════════════════

# Public IP for the jump VM — static so the address doesn't change on restart.
resource "azurerm_public_ip" "bastion" {
  name                = "${var.name}-pip"
  resource_group_name = var.resource_group_name
  location            = var.location
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = merge(var.tags, { module = "bastion" })
}

# Network interface for the jump VM.
resource "azurerm_network_interface" "bastion" {
  name                = "${var.name}-nic"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = merge(var.tags, { module = "bastion" })

  ip_configuration {
    name                          = "internal"
    subnet_id                     = var.subnet_id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.bastion.id
  }
}

# NSG — restrict inbound SSH to specified CIDRs only.
resource "azurerm_network_security_group" "bastion" {
  name                = "${var.name}-nsg"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = merge(var.tags, { module = "bastion" })

  security_rule {
    name                       = "allow-ssh"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefixes    = var.allowed_ssh_cidrs
    destination_address_prefix = "*"
  }
}

resource "azurerm_network_interface_security_group_association" "bastion" {
  network_interface_id      = azurerm_network_interface.bastion.id
  network_security_group_id = azurerm_network_security_group.bastion.id
}

# Jump VM — Ubuntu LTS, Azure AD SSH login, no password auth.
resource "azurerm_linux_virtual_machine" "bastion" {
  name                            = var.name
  resource_group_name             = var.resource_group_name
  location                        = var.location
  size                            = var.vm_size
  admin_username                  = "azureadmin"
  disable_password_authentication = true
  tags                            = merge(var.tags, { module = "bastion" })

  network_interface_ids = [azurerm_network_interface.bastion.id]

  # System-assigned identity required for Azure AD SSH login extension.
  identity {
    type = "SystemAssigned"
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
    disk_size_gb         = 30
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }

  # Admin SSH key for initial emergency access (az ssh vm is the primary path).
  admin_ssh_key {
    username   = "azureadmin"
    public_key = var.admin_ssh_public_key
  }

  # Cloud-init: install tooling required for LangSmith SA operations.
  custom_data = base64encode(<<-EOF
    #!/bin/bash
    set -e
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq

    # kubectl
    curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.32/deb/Release.key \
      | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
    echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] \
      https://pkgs.k8s.io/core:/stable:/v1.32/deb/ /" \
      > /etc/apt/sources.list.d/kubernetes.list
    apt-get update -qq && apt-get install -y kubectl

    # Helm
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

    # Azure CLI
    curl -fsSL https://aka.ms/InstallAzureCLIDeb | bash

    # jq, curl
    apt-get install -y jq curl

    echo "Bastion tooling installed successfully." >> /var/log/bastion-init.log
  EOF
  )
}

# Azure AD SSH Login extension — enables `az ssh vm` without static keys.
resource "azurerm_virtual_machine_extension" "aad_ssh" {
  name                       = "AADSSHLoginForLinux"
  virtual_machine_id         = azurerm_linux_virtual_machine.bastion.id
  publisher                  = "Microsoft.Azure.ActiveDirectory"
  type                       = "AADSSHLoginForLinux"
  type_handler_version       = "1.0"
  auto_upgrade_minor_version = true
  tags                       = merge(var.tags, { module = "bastion" })
}

# Grant the VM's system identity "Virtual Machine Administrator Login" so
# the AAD SSH extension can issue login tokens.
resource "azurerm_role_assignment" "vm_admin_login" {
  scope                = azurerm_linux_virtual_machine.bastion.id
  role_definition_name = "Virtual Machine Administrator Login"
  principal_id         = azurerm_linux_virtual_machine.bastion.identity[0].principal_id
}
