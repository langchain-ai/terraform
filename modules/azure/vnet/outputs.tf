output "vnet_id" {
  value       = azurerm_virtual_network.vnet.id
  description = "The ID of the VNet."
}

output "subnet_main_id" {
  value       = azurerm_subnet.subnet_main.id
  description = "The ID of the main subnet to be used by the AKS cluster."
}

output "subnet_postgres_id" {
  value       = try(azurerm_subnet.subnet_postgres[0].id, null)
  description = "The ID of the Postgres subnet, if created."
}

output "subnet_redis_id" {
  value       = try(azurerm_subnet.subnet_redis[0].id, null)
  description = "The ID of the Redis subnet, if created."
}
