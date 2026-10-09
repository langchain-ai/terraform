output "azure_entra_tenant_id" {
  description = "Entra tenant ID of the subscription."
  value       = data.azurerm_client_config.current.tenant_id
}

output "data_planes" {
  description = "Per data plane key: the resource group ID, the region, and the Key Vault name."
  value = {
    for key, rg in azurerm_resource_group.data_plane : key => {
      resource_group_id = rg.id
      region            = rg.location
      key_vault_name    = azurerm_key_vault.data_plane[key].name
    }
  }
}
