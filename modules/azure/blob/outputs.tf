output "storage_account_name" {
  value = azurerm_storage_account.storage_account.name
}

output "container_name" {
  value = azurerm_storage_container.container.name
}
