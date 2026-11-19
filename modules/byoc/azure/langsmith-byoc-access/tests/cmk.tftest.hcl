# Mocked providers: checks the cmk preconditions, role scopes, and output without Azure.
mock_provider "azurerm" {
  mock_data "azurerm_client_config" { defaults = { tenant_id = "11111111-1111-1111-1111-111111111111" } }
  mock_resource "azurerm_resource_group" { defaults = { id = "/subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/langsmith-byoc-prod", location = "eastus" } }
  mock_resource "azurerm_key_vault" { defaults = { id = "/subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/langsmith-byoc-prod/providers/Microsoft.KeyVault/vaults/ls-prod-abcdef" } }
  mock_resource "azurerm_role_definition" { defaults = { role_definition_resource_id = "/subscriptions/22222222-2222-2222-2222-222222222222/providers/Microsoft.Authorization/roleDefinitions/x" } }
  mock_resource "azurerm_user_assigned_identity" { defaults = { id = "/subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/langsmith-byoc-prod/providers/Microsoft.ManagedIdentity/userAssignedIdentities/langsmith-cmk-identity", principal_id = "33333333-3333-3333-3333-333333333333" } }
  mock_resource "azurerm_disk_encryption_set" { defaults = { id = "/subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/langsmith-byoc-prod/providers/Microsoft.Compute/diskEncryptionSets/langsmith-cmk" } }
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
        key_vault_id = "/subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/security/providers/Microsoft.KeyVault/vaults/contoso-keys"
        key_name     = "langsmith"
      }
    }
  }
}

override_data {
  target = data.azurerm_key_vault.cmk["prod"]
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

run "valid" {
  command = apply
  assert {
    condition     = output.data_planes["prod"].customer_managed_keys.key_id == "https://contoso-keys.vault.azure.net/keys/langsmith"
    error_message = "key_id"
  }
  assert {
    condition     = azurerm_role_assignment.cmk_identity_key["prod"].scope == "/subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/security/providers/Microsoft.KeyVault/vaults/contoso-keys/keys/langsmith"
    error_message = "scope"
  }
  assert {
    condition     = length(azurerm_role_assignment.aks_disk_encryption_set) == 1 && azurerm_disk_encryption_set.cmk["prod"].auto_key_rotation_enabled
    error_message = "des"
  }
}

run "firewall_without_bypass" {
  command = plan
  override_data {
    target = data.azurerm_key_vault.cmk["prod"]
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
  expect_failures = [azurerm_user_assigned_identity.cmk["prod"]]
}

run "other_region_no_purge" {
  command = plan
  override_data {
    target = data.azurerm_key_vault.cmk["prod"]
    values = {
      id                            = "/subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/security/providers/Microsoft.KeyVault/vaults/contoso-keys"
      vault_uri                     = "https://contoso-keys.vault.azure.net/"
      location                      = "westus"
      purge_protection_enabled      = false
      rbac_authorization_enabled    = true
      public_network_access_enabled = true
      network_acls                  = [{ bypass = "None", default_action = "Allow", ip_rules = [], virtual_network_subnet_ids = [] }]
    }
  }
  expect_failures = [azurerm_user_assigned_identity.cmk["prod"]]
}

run "bad_vault_id" {
  command = plan
  variables {
    data_planes = { prod = { location = "eastus", cmk = { key_vault_id = "contoso-keys", key_name = "langsmith" } } }
  }
  expect_failures = [var.data_planes]
}

run "no_cmk" {
  command = plan
  variables {
    data_planes = { prod = { location = "eastus" } }
  }
  assert {
    condition     = length(azurerm_disk_encryption_set.cmk) == 0
    error_message = "no des"
  }
}
