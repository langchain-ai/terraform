output "storage_account_name" {
  value = azurerm_storage_account.storage_account.name
}

output "container_name" {
  value = azurerm_storage_container.container.name
}

output "connection_string" {
  sensitive = true
  value     = azurerm_storage_account.storage_account.primary_connection_string
}
