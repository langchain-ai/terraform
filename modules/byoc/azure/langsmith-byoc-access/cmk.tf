# Customer-managed keys, like customer_managed_keys on AWS: one key for every
# service, a key per service, or both. One set per data plane with cmk set.
# The keys stay in your Key Vaults. LangSmith gets the key URLs and the IDs of
# the identity and the disk encryption set below (output
# data_planes.<key>.customer_managed_keys), never access to the keys: Azure
# checks the access of these two when LangSmith creates each resource. Set cmk
# before you create the data plane. Azure accepts a key only when it creates
# the storage accounts, the PostgreSQL servers, and the AKS cluster.

locals {
  cmk_services = ["blob", "postgres", "disks"]
  # These services reach their key through langsmith-cmk-identity. The disks
  # reach it through the disk encryption set.
  cmk_identity_services = ["blob", "postgres"]

  cmk_data_planes = { for key, dp in var.data_planes : key => dp if dp.cmk != null }

  # Data plane key => service => key resource ID. A service without a
  # service_key_ids entry uses key_id; without key_id, it keeps
  # Microsoft-managed keys.
  cmk_service_keys = {
    for key, dp in local.cmk_data_planes : key => {
      for service in local.cmk_services : service => try(dp.cmk.service_key_ids[service], dp.cmk.key_id)
      if try(dp.cmk.service_key_ids[service], dp.cmk.key_id) != null
    }
  }

  # Data plane key => every key it names. key_id stays in the output even when
  # service_key_ids overrides it for every service.
  cmk_all_keys = {
    for key, dp in local.cmk_data_planes : key => distinct(concat(values(local.cmk_service_keys[key]), dp.cmk.key_id == null ? [] : [dp.cmk.key_id]))
  }

  # Key resource ID => [vault resource ID, key name].
  cmk_key_parts = {
    for id in distinct(flatten(values(local.cmk_all_keys))) :
    id => regex("^(/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\\.KeyVault/vaults/[^/]+)/keys/([^/]+)$", id)
  }

  # "<data plane key>|<vault resource ID>" for each vault that a data plane uses.
  cmk_vaults = merge([
    for key, ids in local.cmk_all_keys : {
      for vault_id in distinct([for id in ids : local.cmk_key_parts[id][0]]) :
      "${key}|${vault_id}" => { data_plane = key, vault_id = vault_id }
    }
  ]...)
}

# Management plane read only: Terraform does not need access to the keys.
data "azurerm_key_vault" "cmk" {
  for_each = local.cmk_vaults

  name                = provider::azurerm::parse_resource_id(each.value.vault_id).resource_name
  resource_group_name = provider::azurerm::parse_resource_id(each.value.vault_id).resource_group_name
}

locals {
  # Data plane key => key resource ID => versionless key URL. Azure uses the
  # newest key version, so a rotation needs no change.
  cmk_key_urls = {
    for key, ids in local.cmk_all_keys : key => {
      for id in ids :
      id => "${trimsuffix(data.azurerm_key_vault.cmk["${key}|${local.cmk_key_parts[id][0]}"].vault_uri, "/")}/keys/${local.cmk_key_parts[id][1]}"
    }
  }

  cmk_identity_data_planes = {
    for key, service_keys in local.cmk_service_keys : key => service_keys
    if length(setintersection(keys(service_keys), local.cmk_identity_services)) > 0
  }
  # "<data plane key>|<key resource ID>" for each key of blob or postgres.
  cmk_identity_keys = merge([
    for key, service_keys in local.cmk_identity_data_planes : {
      for id in distinct([for service in local.cmk_identity_services : service_keys[service] if contains(keys(service_keys), service)]) :
      "${key}|${id}" => { data_plane = key, key_id = id }
    }
  ]...)

  cmk_disk_data_planes = { for key, service_keys in local.cmk_service_keys : key => service_keys["disks"] if contains(keys(service_keys), "disks") }
}

# Each key vault must work with Azure Storage, PostgreSQL, and disk encryption sets.
resource "terraform_data" "cmk_key_vault" {
  for_each = local.cmk_vaults

  input = each.value.vault_id

  lifecycle {
    precondition {
      condition     = data.azurerm_key_vault.cmk[each.key].purge_protection_enabled
      error_message = "The cmk Key Vault ${each.value.vault_id} needs purge protection. Azure Storage, PostgreSQL, and disk encryption sets reject a key without it."
    }
    precondition {
      condition     = data.azurerm_key_vault.cmk[each.key].location == azurerm_resource_group.data_plane[each.value.data_plane].location
      error_message = "The cmk Key Vault ${each.value.vault_id} must be in ${azurerm_resource_group.data_plane[each.value.data_plane].location}, the region of data plane ${each.value.data_plane}. PostgreSQL and disk encryption sets use only a key in their region."
    }
    precondition {
      condition     = data.azurerm_key_vault.cmk[each.key].rbac_authorization_enabled
      error_message = "The cmk Key Vault ${each.value.vault_id} must use Azure RBAC. The module grants access to the keys with role assignments."
    }
    # Storage, PostgreSQL, and disk encryption sets reach the key as trusted
    # Microsoft services, not from a network.
    precondition {
      condition = anytrue([
        for acl in data.azurerm_key_vault.cmk[each.key].network_acls :
        acl.bypass == "AzureServices" || (acl.default_action == "Allow" && data.azurerm_key_vault.cmk[each.key].public_network_access_enabled)
      ])
      error_message = "The cmk Key Vault ${each.value.vault_id} restricts network access. Set \"Allow trusted Microsoft services to bypass this firewall\" (network_acls bypass = AzureServices)."
    }
  }
}

# The Blob storage accounts and the PostgreSQL servers reach their keys
# through this identity.
resource "azurerm_user_assigned_identity" "cmk" {
  for_each = local.cmk_identity_data_planes

  name                = "langsmith-cmk-identity"
  resource_group_name = azurerm_resource_group.data_plane[each.key].name
  location            = azurerm_resource_group.data_plane[each.key].location
  tags                = merge(var.tags, var.data_planes[each.key].tags)

  depends_on = [terraform_data.cmk_key_vault]
}

# Encrypts the OS and data disks of the AKS nodes, and the persistent volumes.
resource "azurerm_disk_encryption_set" "cmk" {
  for_each = local.cmk_disk_data_planes

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

# Wrap and unwrap only: the identities cannot read, change, or delete the keys.
resource "azurerm_role_assignment" "cmk_identity_key" {
  for_each = local.cmk_identity_keys

  scope                = each.value.key_id
  role_definition_name = "Key Vault Crypto Service Encryption User"
  principal_id         = azurerm_user_assigned_identity.cmk[each.value.data_plane].principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_role_assignment" "cmk_disk_encryption_set_key" {
  for_each = local.cmk_disk_data_planes

  scope                = each.value
  role_definition_name = "Key Vault Crypto Service Encryption User"
  principal_id         = azurerm_disk_encryption_set.cmk[each.key].identity[0].principal_id
  principal_type       = "ServicePrincipal"
}

# AKS reads the disk encryption set with its cluster identity. Without byo_iam,
# LangSmith grants this itself.
resource "azurerm_role_assignment" "aks_disk_encryption_set" {
  for_each = { for key, id in local.cmk_disk_data_planes : key => id if var.data_planes[key].byo_iam }

  scope                = azurerm_disk_encryption_set.cmk[each.key].id
  role_definition_name = "Reader"
  principal_id         = azurerm_user_assigned_identity.data_plane["${each.key}/aks"].principal_id
  principal_type       = "ServicePrincipal"
}
