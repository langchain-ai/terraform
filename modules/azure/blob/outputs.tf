output "storage_account_name" {
  value = azurerm_storage_account.storage_account.name
}

output "container_name" {
  value = azurerm_storage_container.container.name
}

output "k8s_managed_identity_client_id" {
  value = azurerm_user_assigned_identity.k8s_app.client_id
}
