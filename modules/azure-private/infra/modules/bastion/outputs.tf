output "public_ip" {
  description = "Public IP address of the bastion VM"
  value       = azurerm_public_ip.bastion.ip_address
}

output "vm_id" {
  description = "Resource ID of the bastion VM"
  value       = azurerm_linux_virtual_machine.bastion.id
}

output "vm_name" {
  description = "Name of the bastion VM"
  value       = azurerm_linux_virtual_machine.bastion.name
}

output "ssh_command" {
  description = "az CLI command to SSH into the bastion VM using Azure AD auth"
  value       = "az ssh vm --name ${azurerm_linux_virtual_machine.bastion.name} --resource-group ${var.resource_group_name}"
}
