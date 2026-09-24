# The VNet and the three service subnets below are null when the resource was
# not created — either the operator brought their own, or the service is
# in-cluster. The root module resolves each against its bring-your-own variable,
# so no downstream module ever receives a null subnet ID.
#
# subnet_bastion_id and subnet_agic_id return an empty string instead, and have
# to: k8s-cluster gates AGIC on agic_subnet_id != "", which a null passes, and
# the split that follows would then fail. Do not switch them to one() for
# consistency with the four above.

output "vnet_id" {
  value       = one(azurerm_virtual_network.vnet[*].id)
  description = "The ID of the VNet, if created."
}

output "subnet_main_id" {
  value       = one(azurerm_subnet.subnet_main[*].id)
  description = "The ID of the main subnet to be used by the AKS cluster, if created."
}

output "subnet_postgres_id" {
  value       = one(azurerm_subnet.subnet_postgres[*].id)
  description = "The ID of the Postgres subnet, if created."
}

output "subnet_redis_id" {
  value       = one(azurerm_subnet.subnet_redis[*].id)
  description = "The ID of the Redis subnet, if created."
}

output "subnet_bastion_id" {
  description = "ID of the bastion subnet (empty string when enable_bastion = false)"
  value       = var.enable_bastion ? azurerm_subnet.subnet_bastion[0].id : ""
}

output "subnet_agic_id" {
  description = "ID of the Application Gateway subnet (empty string when enable_agic = false)"
  value       = var.enable_agic ? azurerm_subnet.subnet_agic[0].id : ""
}

# The VNet's address space, whichever path produced it, so the root module can
# check the overlay pod range against it without knowing which path ran.
output "address_space" {
  description = "Address prefixes of the VNet the subnets live in: the created VNet's, or the existing VNet's when create_vnet = false"
  # address_space is a set on the resource; the root concatenates it with lists.
  value = var.create_vnet ? tolist(one(azurerm_virtual_network.vnet[*].address_space)) : null
}
