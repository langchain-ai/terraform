# Customer-managed keys. LangSmith gets the output customer_managed_keys, not
# access to the keys. Set cmk before you create the data plane.

locals {
  cmk_data_planes = { for key, dp in var.data_planes : key => dp if dp.cmk != null }

  # Data plane => service => key ID. The service key overrides key_id.
  cmk_service_keys = {
    for key, dp in local.cmk_data_planes : key => {
      for service in ["blob", "postgres", "disks"] : service => try(dp.cmk.service_key_ids[service], dp.cmk.key_id)
      if try(dp.cmk.service_key_ids[service], dp.cmk.key_id) != null
    }
  }

  # Data plane => every key ID it names, key_id included.
  cmk_all_keys = {
    for key, dp in local.cmk_data_planes : key => distinct(concat(values(local.cmk_service_keys[key]), compact([dp.cmk.key_id])))
  }

  # Key ID => [vault ID, key name].
  cmk_key_parts = {
    for id in distinct(flatten(values(local.cmk_all_keys))) :
    id => regex("^(/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\\.KeyVault/vaults/[^/]+)/keys/([^/]+)$", id)
  }

  # "<data plane>|<vault ID>" for each vault of a data plane.
  cmk_vaults = merge([
    for key, ids in local.cmk_all_keys : {
      for vault_id in distinct([for id in ids : local.cmk_key_parts[id][0]]) :
      "${key}|${vault_id}" => { data_plane = key, vault_id = vault_id }
    }
  ]...)
}

# Reads only the vault, not the keys.
data "azurerm_key_vault" "cmk" {
  for_each = local.cmk_vaults

  name                = provider::azurerm::parse_resource_id(each.value.vault_id).resource_name
  resource_group_name = provider::azurerm::parse_resource_id(each.value.vault_id).resource_group_name
}

locals {
  # Data plane => key ID => versionless key URL.
  cmk_key_urls = {
    for key, ids in local.cmk_all_keys : key => {
      for id in ids :
      id => "${trimsuffix(data.azurerm_key_vault.cmk["${key}|${local.cmk_key_parts[id][0]}"].vault_uri, "/")}/keys/${local.cmk_key_parts[id][1]}"
    }
  }

  # Data plane => blob and postgres key IDs. They use langsmith-cmk-identity.
  cmk_identity_keys = {
    for key, service_keys in local.cmk_service_keys : key => distinct([for service in ["blob", "postgres"] : service_keys[service] if contains(keys(service_keys), service)])
    if contains(keys(service_keys), "blob") || contains(keys(service_keys), "postgres")
  }

  # Data plane => disks key ID. It uses the disk encryption set.
  cmk_disk_keys = { for key, service_keys in local.cmk_service_keys : key => service_keys["disks"] if contains(keys(service_keys), "disks") }
}

resource "terraform_data" "cmk_key_vault" {
  for_each = local.cmk_vaults

  input = each.value.vault_id

  lifecycle {
    precondition {
      condition     = data.azurerm_key_vault.cmk[each.key].purge_protection_enabled
      error_message = "Key Vault ${each.value.vault_id} needs purge protection."
    }
    precondition {
      condition     = data.azurerm_key_vault.cmk[each.key].location == azurerm_resource_group.data_plane[each.value.data_plane].location
      error_message = "Key Vault ${each.value.vault_id} must be in ${azurerm_resource_group.data_plane[each.value.data_plane].location}, the region of data plane ${each.value.data_plane}."
    }
    precondition {
      condition     = data.azurerm_key_vault.cmk[each.key].rbac_authorization_enabled
      error_message = "Key Vault ${each.value.vault_id} must use Azure RBAC."
    }
    # Azure services reach the keys as trusted services. A vault without
    # network ACLs has no firewall.
    precondition {
      condition = anytrue(concat(
        [length(data.azurerm_key_vault.cmk[each.key].network_acls) == 0 && data.azurerm_key_vault.cmk[each.key].public_network_access_enabled],
        [
          for acl in data.azurerm_key_vault.cmk[each.key].network_acls :
          acl.bypass == "AzureServices" || (acl.default_action == "Allow" && data.azurerm_key_vault.cmk[each.key].public_network_access_enabled)
        ],
      ))
      error_message = "Key Vault ${each.value.vault_id} has a firewall. Allow trusted Microsoft services (network_acls bypass = AzureServices)."
    }
  }
}

resource "azurerm_user_assigned_identity" "cmk" {
  for_each = local.cmk_identity_keys

  name                = "langsmith-cmk-identity"
  resource_group_name = azurerm_resource_group.data_plane[each.key].name
  location            = azurerm_resource_group.data_plane[each.key].location
  tags                = merge(var.tags, var.data_planes[each.key].tags)

  depends_on = [terraform_data.cmk_key_vault]
}

resource "azurerm_disk_encryption_set" "cmk" {
  for_each = local.cmk_disk_keys

  name                      = "langsmith-cmk"
  resource_group_name       = azurerm_resource_group.data_plane[each.key].name
  location                  = azurerm_resource_group.data_plane[each.key].location
  key_vault_key_id          = local.cmk_key_urls[each.key][each.value]
  auto_key_rotation_enabled = true
  tags                      = merge(var.tags, var.data_planes[each.key].tags)

  identity {
    type = "SystemAssigned"
  }

  depends_on = [terraform_data.cmk_key_vault]
}

# Wrap and unwrap only.
resource "azurerm_role_assignment" "cmk_identity_key" {
  for_each = merge([
    for key, ids in local.cmk_identity_keys : { for id in ids : "${key}|${id}" => { data_plane = key, key_id = id } }
  ]...)

  scope                = each.value.key_id
  role_definition_name = "Key Vault Crypto Service Encryption User"
  principal_id         = azurerm_user_assigned_identity.cmk[each.value.data_plane].principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_role_assignment" "cmk_disk_encryption_set_key" {
  for_each = local.cmk_disk_keys

  scope                = each.value
  role_definition_name = "Key Vault Crypto Service Encryption User"
  principal_id         = azurerm_disk_encryption_set.cmk[each.key].identity[0].principal_id
  principal_type       = "ServicePrincipal"
}

# Without byo_iam, LangSmith grants this.
resource "azurerm_role_assignment" "aks_disk_encryption_set" {
  for_each = { for key, id in local.cmk_disk_keys : key => id if var.data_planes[key].byo_iam }

  scope                = azurerm_disk_encryption_set.cmk[each.key].id
  role_definition_name = "Reader"
  principal_id         = azurerm_user_assigned_identity.data_plane["${each.key}/aks"].principal_id
  principal_type       = "ServicePrincipal"
}
