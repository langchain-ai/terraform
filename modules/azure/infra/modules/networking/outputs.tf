# Each output is null when the resource was not created — either the operator
# brought their own, or the service is in-cluster. The root module resolves
# every one against its bring-your-own variable, so no downstream module ever
# receives a null subnet ID.

output "vnet_id" {
  value       = try(azurerm_virtual_network.vnet[0].id, null)
  description = "The ID of the VNet, if created."
}

output "subnet_main_id" {
  value       = try(azurerm_subnet.subnet_main[0].id, null)
  description = "The ID of the main subnet to be used by the AKS cluster, if created."
}

output "subnet_postgres_id" {
  value       = try(azurerm_subnet.subnet_postgres[0].id, null)
  description = "The ID of the Postgres subnet, if created."
}

output "subnet_redis_id" {
  value       = try(azurerm_subnet.subnet_redis[0].id, null)
  description = "The ID of the Redis subnet, if created."
}

output "subnet_bastion_id" {
  description = "ID of the bastion subnet (empty string when enable_bastion = false)"
  value       = try(azurerm_subnet.subnet_bastion[0].id, "")
}

output "subnet_agic_id" {
  description = "ID of the Application Gateway subnet (empty string when enable_agic = false)"
  value       = try(azurerm_subnet.subnet_agic[0].id, "")
}
