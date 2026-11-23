output "azure_entra_tenant_id" {
  description = "Entra tenant ID of the subscription."
  value       = data.azurerm_client_config.current.tenant_id
}

output "data_planes" {
  description = "Per data plane key: the resource group ID, the region, the Key Vault name, and the byovnet object of the create request (null without byo_vnet)."
  value = {
    for key, rg in azurerm_resource_group.data_plane : key => {
      resource_group_id = rg.id
      region            = rg.location
      key_vault_name    = azurerm_key_vault.data_plane[key].name
      byovnet = var.data_planes[key].byo_vnet == null ? null : {
        vnet_id                     = var.data_planes[key].byo_vnet.vnet_id
        aks_subnet_id               = var.data_planes[key].byo_vnet.aks_subnet_id
        private_endpoints_subnet_id = var.data_planes[key].byo_vnet.private_endpoints_subnet_id
        outbound_type               = var.data_planes[key].byo_vnet.outbound_type
      }
    }
  }
}
