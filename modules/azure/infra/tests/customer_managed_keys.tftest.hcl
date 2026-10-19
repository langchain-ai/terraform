# Customer-managed keys: the cluster's disk encryption set, the PostgreSQL
# Flexible Server's key and identities, and the blob storage account's key and
# identity, each an ID the platform team returns. Nothing set leaves the three
# resources on platform-managed keys with no identity block and no role
# assignment, so a cluster created before the setting plans no change. The set
# reaches the cluster resource; the Reader grant on it exists only with the
# flag; the server carries its identity (and the geo-backup identity beside it)
# and the customer_managed_key block; the account carries its identity and
# block. Each refusal run breaks one input: a set ID that is not a disk
# encryption set, a key URL without /keys/, a key without its identity, the
# geo pair without the primary pair, the geo pair with geo-redundant backup
# off, a geo identity equal to the primary one, a storage identity without its
# key (refused on the key variable, which carries the pair check), and the
# Reader grant without a set.

mock_provider "azurerm" {
  mock_data "azurerm_client_config" {
    defaults = {
      tenant_id       = "00000000-0000-0000-0000-000000000000"
      client_id       = "00000000-0000-0000-0000-000000000000"
      object_id       = "00000000-0000-0000-0000-000000000000"
      subscription_id = "00000000-0000-0000-0000-000000000000"
    }
  }
}
# The cluster module lists the subscription's AKS clusters to read the one it
# manages; the generated mock has no such shape, so give it an empty list.
mock_provider "azapi" {
  mock_data "azapi_resource_list" {
    defaults = {
      output = { clusters = [] }
    }
  }
}
mock_provider "kubernetes" {}
mock_provider "helm" {}
mock_provider "null" {}
mock_provider "time" {}

variables {
  subscription_id         = "00000000-0000-0000-0000-000000000000"
  postgres_admin_password = "fixture-not-a-real-secret-Aa1"
}

run "nothing_set_keeps_platform_managed_keys" {
  command = plan

  assert {
    condition     = module.aks.disk_encryption_set_id == null
    error_message = "Without aks_disk_encryption_set_id the cluster should carry no disk encryption set, got ${jsonencode(module.aks.disk_encryption_set_id)}"
  }

  assert {
    condition     = module.aks.disk_encryption_set_reader_scope == null
    error_message = "Without the flag there should be no Reader assignment on a set"
  }

  assert {
    condition     = module.postgres[0].customer_managed_key == null && length(module.postgres[0].identity_ids) == 0
    error_message = "Without the postgres pair the server should carry no customer_managed_key block and no identity"
  }

  assert {
    condition     = module.blob.customer_managed_key == null && length(module.blob.identity_ids) == 0
    error_message = "Without the storage pair the account should carry no customer_managed_key block and no identity"
  }
}

run "the_set_reaches_the_cluster_without_a_grant" {
  command = plan

  variables {
    aks_disk_encryption_set_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/platform-rg/providers/Microsoft.Compute/diskEncryptionSets/des-langsmith"
  }

  assert {
    condition     = module.aks.disk_encryption_set_id == "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/platform-rg/providers/Microsoft.Compute/diskEncryptionSets/des-langsmith"
    error_message = "The set should reach the cluster as given, got ${jsonencode(module.aks.disk_encryption_set_id)}"
  }

  assert {
    condition     = module.aks.disk_encryption_set_reader_scope == null
    error_message = "The Reader grant is the module's only with aks_disk_encryption_set_reader_grant = true"
  }
}

run "the_flag_grants_reader_on_the_set" {
  command = plan

  variables {
    aks_disk_encryption_set_id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/platform-rg/providers/Microsoft.Compute/diskEncryptionSets/des-langsmith"
    aks_disk_encryption_set_reader_grant = true
  }

  assert {
    condition     = module.aks.disk_encryption_set_reader_scope == "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/platform-rg/providers/Microsoft.Compute/diskEncryptionSets/des-langsmith"
    error_message = "With the flag there should be one Reader assignment scoped to the set"
  }
}

run "the_postgres_pair_reaches_the_server" {
  command = plan

  variables {
    postgres_customer_managed_key_id          = "https://kv-keys.vault.usgovcloudapi.net/keys/pg-key"
    postgres_customer_managed_key_identity_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/platform-rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/pg-cmk"
  }

  assert {
    condition     = module.postgres[0].customer_managed_key.key_vault_key_id == "https://kv-keys.vault.usgovcloudapi.net/keys/pg-key" && module.postgres[0].customer_managed_key.primary_user_assigned_identity_id == "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/platform-rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/pg-cmk"
    error_message = "The key and the identity should reach the server's customer_managed_key block"
  }

  assert {
    condition     = module.postgres[0].identity_ids == toset(["/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/platform-rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/pg-cmk"])
    error_message = "The server should carry the identity in identity_ids, got ${jsonencode(module.postgres[0].identity_ids)}"
  }

  assert {
    condition     = module.postgres[0].customer_managed_key.geo_backup_key_vault_key_id == null
    error_message = "Without the geo pair the block should carry no geo-backup key"
  }
}

run "the_geo_pair_reaches_the_server_with_geo_redundant_backup" {
  command = plan

  variables {
    postgres_geo_redundant_backup                        = true
    postgres_customer_managed_key_id                     = "https://kv-keys.vault.usgovcloudapi.net/keys/pg-key"
    postgres_customer_managed_key_identity_id            = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/platform-rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/pg-cmk"
    postgres_geo_backup_customer_managed_key_id          = "https://kv-keys-paired.vault.usgovcloudapi.net/keys/pg-geo-key/0123456789abcdef0123456789abcdef"
    postgres_geo_backup_customer_managed_key_identity_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/platform-rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/pg-cmk-paired"
  }

  assert {
    condition     = module.postgres[0].customer_managed_key.geo_backup_key_vault_key_id == "https://kv-keys-paired.vault.usgovcloudapi.net/keys/pg-geo-key/0123456789abcdef0123456789abcdef" && module.postgres[0].customer_managed_key.geo_backup_user_assigned_identity_id == "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/platform-rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/pg-cmk-paired"
    error_message = "The geo-backup key and identity should reach the server's customer_managed_key block"
  }

  assert {
    condition     = module.postgres[0].identity_ids == toset(["/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/platform-rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/pg-cmk", "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/platform-rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/pg-cmk-paired"])
    error_message = "Both identities should be assigned to the server, got ${jsonencode(module.postgres[0].identity_ids)}"
  }
}

run "the_storage_pair_reaches_the_account" {
  command = plan

  variables {
    storage_customer_managed_key_id          = "https://kv-keys.vault.usgovcloudapi.net/keys/blob-key"
    storage_customer_managed_key_identity_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/platform-rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/blob-cmk"
  }

  assert {
    condition     = module.blob.customer_managed_key.key_vault_key_id == "https://kv-keys.vault.usgovcloudapi.net/keys/blob-key" && module.blob.customer_managed_key.user_assigned_identity_id == "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/platform-rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/blob-cmk"
    error_message = "The key and the identity should reach the account's customer_managed_key block"
  }

  assert {
    condition     = module.blob.identity_ids == toset(["/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/platform-rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/blob-cmk"])
    error_message = "The account should carry the identity, got ${jsonencode(module.blob.identity_ids)}"
  }
}

run "refuses_a_set_id_that_is_not_a_disk_encryption_set" {
  command = plan

  variables {
    aks_disk_encryption_set_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/platform-rg/providers/Microsoft.KeyVault/vaults/kv-keys"
  }

  expect_failures = [var.aks_disk_encryption_set_id]
}

run "refuses_a_key_url_without_keys" {
  command = plan

  variables {
    postgres_customer_managed_key_id          = "https://kv-keys.vault.usgovcloudapi.net/secrets/pg-key"
    postgres_customer_managed_key_identity_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/platform-rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/pg-cmk"
  }

  expect_failures = [var.postgres_customer_managed_key_id]
}

run "refuses_a_postgres_key_without_its_identity" {
  command = plan

  variables {
    postgres_customer_managed_key_id = "https://kv-keys.vault.usgovcloudapi.net/keys/pg-key"
  }

  expect_failures = [var.postgres_customer_managed_key_id]
}

run "refuses_the_geo_pair_without_the_primary_pair" {
  command = plan

  variables {
    postgres_geo_redundant_backup                        = true
    postgres_geo_backup_customer_managed_key_id          = "https://kv-keys-paired.vault.usgovcloudapi.net/keys/pg-geo-key/0123456789abcdef0123456789abcdef"
    postgres_geo_backup_customer_managed_key_identity_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/platform-rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/pg-cmk-paired"
  }

  expect_failures = [var.postgres_geo_backup_customer_managed_key_id]
}

run "refuses_the_geo_pair_with_geo_redundant_backup_off" {
  command = plan

  variables {
    postgres_customer_managed_key_id                     = "https://kv-keys.vault.usgovcloudapi.net/keys/pg-key"
    postgres_customer_managed_key_identity_id            = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/platform-rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/pg-cmk"
    postgres_geo_backup_customer_managed_key_id          = "https://kv-keys-paired.vault.usgovcloudapi.net/keys/pg-geo-key/0123456789abcdef0123456789abcdef"
    postgres_geo_backup_customer_managed_key_identity_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/platform-rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/pg-cmk-paired"
  }

  expect_failures = [var.postgres_geo_backup_customer_managed_key_id]
}

run "refuses_a_geo_identity_equal_to_the_primary" {
  command = plan

  variables {
    postgres_geo_redundant_backup                        = true
    postgres_customer_managed_key_id                     = "https://kv-keys.vault.usgovcloudapi.net/keys/pg-key"
    postgres_customer_managed_key_identity_id            = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/platform-rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/pg-cmk"
    postgres_geo_backup_customer_managed_key_id          = "https://kv-keys-paired.vault.usgovcloudapi.net/keys/pg-geo-key/0123456789abcdef0123456789abcdef"
    postgres_geo_backup_customer_managed_key_identity_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/platform-rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/pg-cmk"
  }

  expect_failures = [var.postgres_geo_backup_customer_managed_key_identity_id]
}

run "refuses_a_storage_identity_without_its_key" {
  command = plan

  variables {
    storage_customer_managed_key_identity_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/platform-rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/blob-cmk"
  }

  expect_failures = [var.storage_customer_managed_key_id]
}

run "refuses_the_reader_grant_without_a_set" {
  command = plan

  variables {
    aks_disk_encryption_set_reader_grant = true
  }

  expect_failures = [var.aks_disk_encryption_set_reader_grant]
}

# Azure encrypts a customer-managed-key server's geo-redundant backups only
# with a key in the backup region; without the geo pair the create fails late.
run "refuses_the_primary_pair_with_geo_redundant_backup_and_no_geo_pair" {
  command = plan

  variables {
    postgres_customer_managed_key_id          = "https://kv-keys.vault.usgovcloudapi.net/keys/pg-key"
    postgres_customer_managed_key_identity_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/platform-rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/pg-cmk"
    postgres_geo_redundant_backup             = true
  }

  expect_failures = [var.postgres_geo_backup_customer_managed_key_id]
}
