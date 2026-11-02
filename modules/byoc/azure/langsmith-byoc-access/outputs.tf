output "azure_entra_tenant_id" {
  description = "Entra tenant ID of the subscription."
  value       = data.azurerm_client_config.current.tenant_id
}

output "data_planes" {
  description = "Per data plane key: the resource group ID, the region, the Key Vault name, and the byovnet object of the create request (null without existing_network)."
  value = {
    for key, rg in azurerm_resource_group.data_plane : key => {
      resource_group_id = rg.id
      region            = rg.location
      key_vault_name    = azurerm_key_vault.data_plane[key].name
      byovnet = try({
        vnet_id                = local.existing_networks[key].vnet_id
        aks_subnet_id          = local.existing_networks[key].aks_subnet_id
        postgres_subnet_id     = local.existing_networks[key].postgres_subnet_id
        redis_subnet_id        = local.existing_networks[key].redis_subnet_id
        private_link_subnet_id = local.existing_networks[key].private_link_subnet_id
        outbound_type          = local.existing_networks[key].outbound_type
        aks_identity_id        = azurerm_user_assigned_identity.aks[key].id
      }, null)
    }
  }
}
