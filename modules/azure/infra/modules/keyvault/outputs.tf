output "vault_id" {
  value       = local.vault_id
  description = "Resource ID of the Key Vault"
}

output "vault_name" {
  value       = local.vault_name
  description = "Name of the Key Vault — used by setup-env.sh to read/write secrets"
}

output "vault_uri" {
  value       = local.vault_uri
  description = "URI of the Key Vault (https://<name>.vault.azure.net/)"
}

output "terraform_admin_principal_id" {
  value       = var.manage_terraform_admin_assignment ? azurerm_role_assignment.terraform_kv_admin[0].principal_id : null
  description = "Object ID granted 'Key Vault Secrets Officer' for the apply identity, or null when that grant is skipped"
}

output "private_endpoint_id" {
  description = "Resource ID of the vault's Private Endpoint, or null when there is none."
  value       = try(azurerm_private_endpoint.vault[0].id, null)
}

output "private_endpoint_dns_zone_id" {
  description = "The private DNS zone the vault's Private Endpoint registers its record in, or null when there is no endpoint."
  value       = try(azurerm_private_endpoint.vault[0].private_dns_zone_group[0].private_dns_zone_ids[0], null)
}

output "public_network_access_enabled" {
  description = "Whether the vault this module created accepts traffic on its public endpoint. Null for a supplied vault, whose setting is its owner's."
  value       = try(azurerm_key_vault.langsmith[0].public_network_access_enabled, null)
}

output "firewall_subnet_ids" {
  description = "Subnets allowlisted on the vault's firewall, or null for a supplied vault, whose firewall is its owner's."
  value       = var.create_keyvault ? var.allowed_subnet_ids : null
}
