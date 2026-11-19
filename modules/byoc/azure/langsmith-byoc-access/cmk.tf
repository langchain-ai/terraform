# Customer-managed keys. One set per data plane with cmk set. The key stays in
# your Key Vault. LangSmith gets the key ID and the IDs of the identity and the
# disk encryption set below (output data_planes.<key>.customer_managed_keys),
# never access to the key: Azure checks the access of these two when LangSmith
# creates each resource. Set cmk before you create the data plane. Azure allows
# the key only when it creates the storage accounts, the PostgreSQL servers,
# and the AKS cluster.

locals {
  cmk_data_planes = { for key, dp in var.data_planes : key => dp if dp.cmk != null }

  cmk_key_vaults = {
    for key, dp in local.cmk_data_planes : key => provider::azurerm::parse_resource_id(dp.cmk.key_vault_id)
  }
}

# Management plane read only: Terraform does not need access to the keys.
data "azurerm_key_vault" "cmk" {
  for_each = local.cmk_data_planes

  name                = local.cmk_key_vaults[each.key].resource_name
  resource_group_name = local.cmk_key_vaults[each.key].resource_group_name
}

locals {
  # Versionless: Azure uses the newest key version, so a rotation needs no change.
  cmk_key_ids = {
    for key, vault in data.azurerm_key_vault.cmk : key => "${trimsuffix(vault.vault_uri, "/")}/keys/${local.cmk_data_planes[key].cmk.key_name}"
  }
  # The role assignments on the key use its resource ID.
  cmk_key_resource_ids = {
    for key, vault in data.azurerm_key_vault.cmk : key => "${vault.id}/keys/${local.cmk_data_planes[key].cmk.key_name}"
  }
}

# The Blob storage accounts and the PostgreSQL servers reach the key through
# this identity.
resource "azurerm_user_assigned_identity" "cmk" {
  for_each = local.cmk_data_planes

  name                = "langsmith-cmk-identity"
  resource_group_name = azurerm_resource_group.data_plane[each.key].name
  location            = azurerm_resource_group.data_plane[each.key].location
  tags                = merge(var.tags, each.value.tags)

  lifecycle {
    precondition {
      condition     = data.azurerm_key_vault.cmk[each.key].purge_protection_enabled
      error_message = "The cmk Key Vault of data plane ${each.key} needs purge protection. Azure Storage, PostgreSQL, and disk encryption sets reject a key without it."
    }
    precondition {
      condition     = data.azurerm_key_vault.cmk[each.key].location == azurerm_resource_group.data_plane[each.key].location
      error_message = "The cmk Key Vault of data plane ${each.key} must be in ${azurerm_resource_group.data_plane[each.key].location}. PostgreSQL and disk encryption sets use only a key in their region."
    }
    precondition {
      condition     = data.azurerm_key_vault.cmk[each.key].rbac_authorization_enabled
      error_message = "The cmk Key Vault of data plane ${each.key} must use Azure RBAC. The module grants access to the key with role assignments."
    }
    # Storage, PostgreSQL, and disk encryption sets reach the key as trusted
    # Microsoft services, not from a network.
    precondition {
      condition = anytrue([
        for acl in data.azurerm_key_vault.cmk[each.key].network_acls :
        acl.bypass == "AzureServices" || (acl.default_action == "Allow" && data.azurerm_key_vault.cmk[each.key].public_network_access_enabled)
      ])
      error_message = "The cmk Key Vault of data plane ${each.key} restricts network access. Set \"Allow trusted Microsoft services to bypass this firewall\" (network_acls bypass = AzureServices)."
    }
  }
}

# Encrypts the OS and data disks of the AKS nodes, and the persistent volumes.
resource "azurerm_disk_encryption_set" "cmk" {
  for_each = local.cmk_data_planes

  name                      = "langsmith-cmk"
  resource_group_name       = azurerm_resource_group.data_plane[each.key].name
  location                  = azurerm_resource_group.data_plane[each.key].location
  key_vault_key_id          = local.cmk_key_ids[each.key]
  auto_key_rotation_enabled = true
  tags                      = merge(var.tags, each.value.tags)

  identity {
    type = "SystemAssigned"
  }

  # The identity checks of the key vault run first.
  depends_on = [azurerm_user_assigned_identity.cmk]
}

# Wrap and unwrap only: the identities cannot read, change, or delete the key.
resource "azurerm_role_assignment" "cmk_identity_key" {
  for_each = local.cmk_data_planes

  scope                = local.cmk_key_resource_ids[each.key]
  role_definition_name = "Key Vault Crypto Service Encryption User"
  principal_id         = azurerm_user_assigned_identity.cmk[each.key].principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_role_assignment" "cmk_disk_encryption_set_key" {
  for_each = local.cmk_data_planes

  scope                = local.cmk_key_resource_ids[each.key]
  role_definition_name = "Key Vault Crypto Service Encryption User"
  principal_id         = azurerm_disk_encryption_set.cmk[each.key].identity[0].principal_id
  principal_type       = "ServicePrincipal"
}

# AKS reads the disk encryption set with its cluster identity. Without byo_iam,
# LangSmith grants this itself.
resource "azurerm_role_assignment" "aks_disk_encryption_set" {
  for_each = { for key, dp in local.cmk_data_planes : key => dp if dp.byo_iam }

  scope                = azurerm_disk_encryption_set.cmk[each.key].id
  role_definition_name = "Reader"
  principal_id         = azurerm_user_assigned_identity.data_plane["${each.key}/aks"].principal_id
  principal_type       = "ServicePrincipal"
}
