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
