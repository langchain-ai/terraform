output "azure_entra_tenant_id" {
  description = "Entra tenant ID of the subscription."
  value       = data.azurerm_client_config.current.tenant_id
}

output "data_planes" {
  description = "Per data plane key: the resource group ID, the region, the Key Vault name, and, with cmk, the customer_managed_keys value for the LangSmith create request."
  value = {
    for key, rg in azurerm_resource_group.data_plane : key => {
      resource_group_id = rg.id
      region            = rg.location
      key_vault_name    = azurerm_key_vault.data_plane[key].name
      customer_managed_keys = contains(keys(local.cmk_data_planes), key) ? {
        key_id                 = local.cmk_key_ids[key]
        identity_id            = azurerm_user_assigned_identity.cmk[key].id
        disk_encryption_set_id = azurerm_disk_encryption_set.cmk[key].id
      } : null
    }
  }
}
