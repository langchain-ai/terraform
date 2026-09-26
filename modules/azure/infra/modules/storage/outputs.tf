output "storage_account_name" {
  value = azurerm_storage_account.storage_account.name
}

output "container_name" {
  value = azurerm_storage_container.container.name
}

output "storage_account_id" {
  description = "Resource ID of the LangSmith trace-blob Storage Account."
  value       = azurerm_storage_account.storage_account.id
}

output "k8s_managed_identity_client_id" {
  value = var.workload_identity_client_id
}

output "k8s_managed_identity_principal_id" {
  description = "Object ID of the managed identity — used by the keyvault module to grant Key Vault Secrets User role"
  value       = var.workload_identity_principal_id
}

output "blob_endpoint" {
  description = "Blob service endpoint of the trace-blob account, as Azure reports it for this cloud (https://<name>.blob.core.windows.net/ in commercial Azure)."
  value       = azurerm_storage_account.storage_account.primary_blob_endpoint
}
