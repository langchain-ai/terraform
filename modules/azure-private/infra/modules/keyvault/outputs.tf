output "vault_id" {
  value       = azurerm_key_vault.langsmith.id
  description = "Resource ID of the Key Vault"
}

output "vault_name" {
  value       = azurerm_key_vault.langsmith.name
  description = "Name of the Key Vault — used by setup-env.sh to read/write secrets"
}

output "vault_uri" {
  value       = azurerm_key_vault.langsmith.vault_uri
  description = "URI of the Key Vault (https://<name>.vault.azure.net/)"
}
