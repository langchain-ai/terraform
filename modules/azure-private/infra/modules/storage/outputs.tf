output "storage_account_name" {
  value = azurerm_storage_account.storage_account.name
}

output "container_name" {
  value = azurerm_storage_container.container.name
}

output "k8s_managed_identity_client_id" {
  value = var.workload_identity_client_id
}

output "k8s_managed_identity_principal_id" {
  description = "Object ID of the managed identity — used by the keyvault module to grant Key Vault Secrets User role"
  value       = var.workload_identity_principal_id
}
