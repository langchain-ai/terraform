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
        key_id                 = var.data_planes[key].cmk.key_id == null ? null : local.cmk_key_urls[key][var.data_planes[key].cmk.key_id]
        service_key_ids        = { for service, id in var.data_planes[key].cmk.service_key_ids : service => local.cmk_key_urls[key][id] }
        identity_id            = try(azurerm_user_assigned_identity.cmk[key].id, null)
        disk_encryption_set_id = try(azurerm_disk_encryption_set.cmk[key].id, null)
      } : null
    }
  }
}
