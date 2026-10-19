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

output "replication_type" {
  description = "Replication the account is planned or created with."
  value       = azurerm_storage_account.storage_account.account_replication_type
}

output "shared_access_key_enabled" {
  description = "Whether the account accepts Shared Key authorization, as planned or created."
  value       = azurerm_storage_account.storage_account.shared_access_key_enabled
}

output "allow_nested_items_to_be_public" {
  description = "Whether containers in the account may allow anonymous public access, as planned or created."
  value       = azurerm_storage_account.storage_account.allow_nested_items_to_be_public
}

output "allowed_copy_scope" {
  description = "Which accounts copy operations may source from, as planned or created; null means any."
  value       = azurerm_storage_account.storage_account.allowed_copy_scope
}
