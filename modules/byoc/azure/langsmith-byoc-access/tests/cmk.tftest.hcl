# Mocked providers: cmk keys, vault checks, role scopes, and output.
mock_provider "azurerm" {
  mock_data "azurerm_client_config" {
    defaults = { tenant_id = "11111111-1111-1111-1111-111111111111" }
  }
  mock_resource "azurerm_resource_group" {
    defaults = { id = "/subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/langsmith-byoc-prod", location = "eastus" }
  }
  mock_resource "azurerm_key_vault" {
    defaults = { id = "/subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/langsmith-byoc-prod/providers/Microsoft.KeyVault/vaults/ls-prod-abcdef" }
  }
  mock_resource "azurerm_role_definition" {
    defaults = { role_definition_resource_id = "/subscriptions/22222222-2222-2222-2222-222222222222/providers/Microsoft.Authorization/roleDefinitions/x" }
  }
  mock_resource "azurerm_user_assigned_identity" {
    defaults = { id = "/subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/langsmith-byoc-prod/providers/Microsoft.ManagedIdentity/userAssignedIdentities/langsmith-cmk-identity", principal_id = "33333333-3333-3333-3333-333333333333" }
  }
  mock_resource "azurerm_disk_encryption_set" {
    defaults = { id = "/subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/langsmith-byoc-prod/providers/Microsoft.Compute/diskEncryptionSets/langsmith-cmk" }
  }
}
mock_provider "azuread" {}
mock_provider "random" {}

variables {
  langsmith_app_client_id = "55555555-5555-5555-5555-555555555555"
  external_id             = "ext"
  data_planes = {
    prod = {
      location = "eastus"
      byo_iam  = true
      cmk = {
        key_id = "/subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/security/providers/Microsoft.KeyVault/vaults/contoso-keys/keys/langsmith"
      }
    }
  }
}

override_data {
  target = data.azurerm_key_vault.cmk["prod|/subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/security/providers/Microsoft.KeyVault/vaults/contoso-keys"]
  values = {
    id                            = "/subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/security/providers/Microsoft.KeyVault/vaults/contoso-keys"
    vault_uri                     = "https://contoso-keys.vault.azure.net/"
    location                      = "eastus"
    purge_protection_enabled      = true
    rbac_authorization_enabled    = true
    public_network_access_enabled = false
    network_acls                  = [{ bypass = "AzureServices", default_action = "Deny", ip_rules = [], virtual_network_subnet_ids = [] }]
  }
}

override_data {
  target = data.azurerm_key_vault.cmk["prod|/subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/security/providers/Microsoft.KeyVault/vaults/contoso-pg"]
  values = {
    id                            = "/subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/security/providers/Microsoft.KeyVault/vaults/contoso-pg"
    vault_uri                     = "https://contoso-pg.vault.azure.net/"
    location                      = "eastus"
    purge_protection_enabled      = true
    rbac_authorization_enabled    = true
    public_network_access_enabled = true
    network_acls                  = [{ bypass = "None", default_action = "Allow", ip_rules = [], virtual_network_subnet_ids = [] }]
  }
}

run "one_key" {
  command = apply
  assert {
    condition = output.data_planes["prod"].customer_managed_keys == {
      key_id                 = "https://contoso-keys.vault.azure.net/keys/langsmith"
      service_key_ids        = {}
      identity_id            = "/subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/langsmith-byoc-prod/providers/Microsoft.ManagedIdentity/userAssignedIdentities/langsmith-cmk-identity"
      disk_encryption_set_id = "/subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/langsmith-byoc-prod/providers/Microsoft.Compute/diskEncryptionSets/langsmith-cmk"
    }
    error_message = "customer_managed_keys"
  }
  assert {
    condition     = [for a in azurerm_role_assignment.cmk_identity_key : a.scope] == ["/subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/security/providers/Microsoft.KeyVault/vaults/contoso-keys/keys/langsmith"]
    error_message = "one identity grant on the key"
  }
  assert {
    condition     = azurerm_disk_encryption_set.cmk["prod"].key_vault_key_id == "https://contoso-keys.vault.azure.net/keys/langsmith" && azurerm_disk_encryption_set.cmk["prod"].auto_key_rotation_enabled
    error_message = "disk encryption set key"
  }
  assert {
    condition     = length(azurerm_role_assignment.aks_disk_encryption_set) == 1
    error_message = "byo_iam Reader on the disk encryption set"
  }
}

run "key_per_service" {
  command = plan
  variables {
    data_planes = {
      prod = {
        location = "eastus"
        cmk = {
          key_id          = "/subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/security/providers/Microsoft.KeyVault/vaults/contoso-keys/keys/langsmith"
          service_key_ids = { postgres = "/subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/security/providers/Microsoft.KeyVault/vaults/contoso-pg/keys/pg" }
        }
      }
    }
  }
  assert {
    condition     = output.data_planes["prod"].customer_managed_keys.service_key_ids == { postgres = "https://contoso-pg.vault.azure.net/keys/pg" }
    error_message = "service_key_ids"
  }
  assert {
    condition     = length(azurerm_role_assignment.cmk_identity_key) == 2 && length(terraform_data.cmk_key_vault) == 2
    error_message = "identity grants on both keys, checks on both vaults"
  }
  assert {
    condition     = length(azurerm_role_assignment.aks_disk_encryption_set) == 0
    error_message = "LangSmith grants Reader without byo_iam"
  }
}

run "disks_only" {
  command = plan
  variables {
    data_planes = {
      prod = {
        location = "eastus"
        cmk = {
          service_key_ids = { disks = "/subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/security/providers/Microsoft.KeyVault/vaults/contoso-keys/keys/disks" }
        }
      }
    }
  }
  assert {
    condition     = length(azurerm_user_assigned_identity.cmk) == 0 && output.data_planes["prod"].customer_managed_keys.identity_id == null && output.data_planes["prod"].customer_managed_keys.key_id == null
    error_message = "no identity without blob or postgres"
  }
  assert {
    condition     = azurerm_disk_encryption_set.cmk["prod"].key_vault_key_id == "https://contoso-keys.vault.azure.net/keys/disks"
    error_message = "disk encryption set key"
  }
}

run "blob_only" {
  command = plan
  variables {
    data_planes = {
      prod = {
        location = "eastus"
        cmk = {
          service_key_ids = { blob = "/subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/security/providers/Microsoft.KeyVault/vaults/contoso-keys/keys/blob" }
        }
      }
    }
  }
  assert {
    condition     = length(azurerm_disk_encryption_set.cmk) == 0 && output.data_planes["prod"].customer_managed_keys.disk_encryption_set_id == null
    error_message = "no disk encryption set without disks"
  }
}

run "firewall_without_bypass" {
  command = plan
  override_data {
    target = data.azurerm_key_vault.cmk["prod|/subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/security/providers/Microsoft.KeyVault/vaults/contoso-keys"]
    values = {
      id                            = "/subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/security/providers/Microsoft.KeyVault/vaults/contoso-keys"
      vault_uri                     = "https://contoso-keys.vault.azure.net/"
      location                      = "eastus"
      purge_protection_enabled      = true
      rbac_authorization_enabled    = true
      public_network_access_enabled = true
      network_acls                  = [{ bypass = "None", default_action = "Deny", ip_rules = [], virtual_network_subnet_ids = [] }]
    }
  }
  expect_failures = [terraform_data.cmk_key_vault["prod|/subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/security/providers/Microsoft.KeyVault/vaults/contoso-keys"]]
}

run "other_region" {
  command = plan
  override_data {
    target = data.azurerm_key_vault.cmk["prod|/subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/security/providers/Microsoft.KeyVault/vaults/contoso-keys"]
    values = {
      id                            = "/subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/security/providers/Microsoft.KeyVault/vaults/contoso-keys"
      vault_uri                     = "https://contoso-keys.vault.azure.net/"
      location                      = "westus"
      purge_protection_enabled      = true
      rbac_authorization_enabled    = true
      public_network_access_enabled = true
      network_acls                  = [{ bypass = "None", default_action = "Allow", ip_rules = [], virtual_network_subnet_ids = [] }]
    }
  }
  expect_failures = [terraform_data.cmk_key_vault["prod|/subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/security/providers/Microsoft.KeyVault/vaults/contoso-keys"]]
}

run "unknown_service" {
  command = plan
  variables {
    data_planes = { prod = { location = "eastus", cmk = { service_key_ids = { redis = "/subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/security/providers/Microsoft.KeyVault/vaults/contoso-keys/keys/x" } } } }
  }
  expect_failures = [var.data_planes]
}

run "no_key" {
  command = plan
  variables {
    data_planes = { prod = { location = "eastus", cmk = {} } }
  }
  expect_failures = [var.data_planes]
}

run "key_url_instead_of_id" {
  command = plan
  variables {
    data_planes = { prod = { location = "eastus", cmk = { key_id = "https://contoso-keys.vault.azure.net/keys/langsmith" } } }
  }
  expect_failures = [var.data_planes]
}

run "no_cmk" {
  command = plan
  variables {
    data_planes = { prod = { location = "eastus" } }
  }
  assert {
    condition     = length(azurerm_disk_encryption_set.cmk) == 0 && output.data_planes["prod"].customer_managed_keys == null
    error_message = "no cmk resources"
  }
}

run "public_vault_without_acls" {
  command = plan
  override_data {
    target = data.azurerm_key_vault.cmk["prod|/subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/security/providers/Microsoft.KeyVault/vaults/contoso-keys"]
    values = {
      id                            = "/subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/security/providers/Microsoft.KeyVault/vaults/contoso-keys"
      vault_uri                     = "https://contoso-keys.vault.azure.net/"
      location                      = "eastus"
      purge_protection_enabled      = true
      rbac_authorization_enabled    = true
      public_network_access_enabled = true
      network_acls                  = []
    }
  }
}

run "private_vault_without_acls" {
  command = plan
  override_data {
    target = data.azurerm_key_vault.cmk["prod|/subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/security/providers/Microsoft.KeyVault/vaults/contoso-keys"]
    values = {
      id                            = "/subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/security/providers/Microsoft.KeyVault/vaults/contoso-keys"
      vault_uri                     = "https://contoso-keys.vault.azure.net/"
      location                      = "eastus"
      purge_protection_enabled      = true
      rbac_authorization_enabled    = true
      public_network_access_enabled = false
      network_acls                  = []
    }
  }
  expect_failures = [terraform_data.cmk_key_vault["prod|/subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/security/providers/Microsoft.KeyVault/vaults/contoso-keys"]]
}
