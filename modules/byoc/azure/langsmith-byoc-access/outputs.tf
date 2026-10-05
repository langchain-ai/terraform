output "tenant_id" {
  description = "Entra tenant ID of the subscription."
  value       = data.azurerm_client_config.current.tenant_id
}

output "subscription_id" {
  description = "Azure subscription ID that holds the data plane resource groups."
  value       = data.azurerm_client_config.current.subscription_id
}

output "service_principal_object_id" {
  description = "Object ID of the LangSmith service principal in this tenant."
  value       = azuread_service_principal.langsmith.object_id
}

output "data_planes" {
  description = "Per data plane key: the resource group name, the region, and the Key Vault name."
  value = {
    for key, rg in azurerm_resource_group.data_plane : key => {
      resource_group_name = rg.name
      region              = rg.location
      key_vault_name      = azurerm_key_vault.data_plane[key].name
    }
  }
}
