# Per-store customer-managed keys (PRO-190): SmithDB's metastore and storage
# account take their own key, or LangSmith's when theirs is empty; the SmithDB
# cache and JuiceFS Redis StorageClasses name their own disk encryption set, or
# the cluster's; the cluster identity gets Reader on each further set, once per
# distinct set. Refusal runs break one input each: a bad key URL, a bad
# identity ID, a key without its identity, a per-store key without SmithDB, a
# bad set ID, a set for a class the module does not create, and the Reader
# grant with no set at all.

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
# The cluster module and the metastore guard list resources; an empty list
# reads as "nothing exists yet", which the guards pass.
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
  availability_zones      = ["1", "2", "3"]
}

run "smithdb_without_keys_keeps_service_managed_keys" {
  command = plan

  variables {
    enable_smithdb = true
  }

  assert {
    condition     = module.smithdb[0].metastore_customer_managed_key == null && length(module.smithdb[0].metastore_identity_ids) == 0
    error_message = "Without any key the metastore should carry no customer_managed_key block and no identity"
  }

  assert {
    condition     = module.smithdb[0].storage_customer_managed_key == null && length(module.smithdb[0].storage_identity_ids) == 0
    error_message = "Without any key the SmithDB account should carry no customer_managed_key block and no identity"
  }

  assert {
    condition     = module.k8s_bootstrap.storage_class_disk_encryption_set_ids.smithdb_cache == null
    error_message = "Without a set the cache StorageClass should name none, got ${jsonencode(module.k8s_bootstrap.storage_class_disk_encryption_set_ids.smithdb_cache)}"
  }

  assert {
    condition     = length(module.aks.additional_disk_encryption_set_reader_scopes) == 0
    error_message = "Without sets there should be no further Reader assignment"
  }
}

run "smithdb_falls_back_to_langsmith_keys_and_the_cluster_set" {
  command = plan

  variables {
    enable_smithdb                            = true
    postgres_customer_managed_key_id          = "https://kv-langsmith.vault.azure.net/keys/postgres"
    postgres_customer_managed_key_identity_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/platform-rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-postgres"
    storage_customer_managed_key_id           = "https://kv-langsmith.vault.azure.net/keys/storage"
    storage_customer_managed_key_identity_id  = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/platform-rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-storage"
    aks_disk_encryption_set_id                = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/platform-rg/providers/Microsoft.Compute/diskEncryptionSets/des-cluster"
    aks_disk_encryption_set_reader_grant      = true
  }

  assert {
    condition = module.smithdb[0].metastore_customer_managed_key == {
      key_vault_key_id                  = "https://kv-langsmith.vault.azure.net/keys/postgres"
      primary_user_assigned_identity_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/platform-rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-postgres"
    }
    error_message = "The metastore should take LangSmith's PostgreSQL key and identity, got ${jsonencode(module.smithdb[0].metastore_customer_managed_key)}"
  }

  assert {
    condition = module.smithdb[0].storage_customer_managed_key == {
      key_vault_key_id          = "https://kv-langsmith.vault.azure.net/keys/storage"
      user_assigned_identity_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/platform-rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-storage"
    }
    error_message = "The SmithDB account should take LangSmith's storage key and identity, got ${jsonencode(module.smithdb[0].storage_customer_managed_key)}"
  }

  assert {
    condition     = module.k8s_bootstrap.storage_class_disk_encryption_set_ids.smithdb_cache == "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/platform-rg/providers/Microsoft.Compute/diskEncryptionSets/des-cluster"
    error_message = "The cache StorageClass should name the cluster's set, got ${jsonencode(module.k8s_bootstrap.storage_class_disk_encryption_set_ids.smithdb_cache)}"
  }

  assert {
    condition     = length(module.aks.additional_disk_encryption_set_reader_scopes) == 0
    error_message = "The cluster's set keeps its own grant, so no further Reader assignment should be planned, got ${jsonencode(module.aks.additional_disk_encryption_set_reader_scopes)}"
  }
}

run "an_existing_unkeyed_metastore_keeps_the_service_managed_key" {
  command = plan

  variables {
    enable_smithdb                            = true
    postgres_customer_managed_key_id          = "https://kv-langsmith.vault.azure.net/keys/postgres"
    postgres_customer_managed_key_identity_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/platform-rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-postgres"
  }

  override_data {
    target = data.azapi_resource_list.smithdb_metastore_servers[0]
    values = {
      output = { servers = [{ id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.DBforPostgreSQL/flexibleServers/x-metastore", name = "x-metastore", data_encryption = "SystemManaged" }] }
    }
  }

  # The fallback is skipped, so the guard passes and the plan warns instead.
  expect_failures = [check.smithdb_metastore_keeps_service_managed_key]

  assert {
    condition     = module.smithdb[0].metastore_customer_managed_key == null
    error_message = "An existing unkeyed metastore should keep the service-managed key, got ${jsonencode(module.smithdb[0].metastore_customer_managed_key)}"
  }
}

run "per_store_keys_and_sets_win_and_get_one_grant_each" {
  command = plan

  variables {
    enable_smithdb                                     = true
    enable_sandboxes                                   = true
    sandbox_juicefs_redis_source                       = "in-cluster"
    postgres_customer_managed_key_id                   = "https://kv-langsmith.vault.azure.net/keys/postgres"
    postgres_customer_managed_key_identity_id          = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/platform-rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-postgres"
    smithdb_metastore_customer_managed_key_id          = "https://kv-smithdb.vault.azure.net/keys/metastore"
    smithdb_metastore_customer_managed_key_identity_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/platform-rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-metastore"
    smithdb_storage_customer_managed_key_id            = "https://kv-smithdb.vault.azure.net/keys/smithdb-storage"
    smithdb_storage_customer_managed_key_identity_id   = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/platform-rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-smithdb-storage"
    aks_disk_encryption_set_id                         = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/platform-rg/providers/Microsoft.Compute/diskEncryptionSets/des-cluster"
    smithdb_cache_disk_encryption_set_id               = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/platform-rg/providers/Microsoft.Compute/diskEncryptionSets/des-smithdb"
    sandbox_juicefs_redis_disk_encryption_set_id       = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/platform-rg/providers/Microsoft.Compute/diskEncryptionSets/des-sandbox"
    # A duplicate of the cache's set in another case, and the cluster's set:
    # neither adds a grant.
    aks_additional_disk_encryption_set_ids = [
      "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/platform-rg/providers/Microsoft.Compute/diskEncryptionSets/des-clickhouse",
      "/subscriptions/00000000-0000-0000-0000-000000000000/resourcegroups/platform-rg/providers/Microsoft.Compute/diskEncryptionSets/DES-SMITHDB",
      "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/platform-rg/providers/Microsoft.Compute/diskEncryptionSets/des-cluster",
    ]
    aks_disk_encryption_set_reader_grant            = true
    aks_additional_disk_encryption_set_reader_grant = true
  }

  assert {
    condition     = module.smithdb[0].metastore_customer_managed_key.key_vault_key_id == "https://kv-smithdb.vault.azure.net/keys/metastore" && module.smithdb[0].metastore_identity_ids == toset(["/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/platform-rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-metastore"])
    error_message = "The metastore should take its own key and only its own identity, got ${jsonencode(module.smithdb[0].metastore_customer_managed_key)}"
  }

  assert {
    condition     = module.smithdb[0].storage_customer_managed_key.key_vault_key_id == "https://kv-smithdb.vault.azure.net/keys/smithdb-storage"
    error_message = "The SmithDB account should take its own key, got ${jsonencode(module.smithdb[0].storage_customer_managed_key)}"
  }

  assert {
    condition     = module.k8s_bootstrap.storage_class_disk_encryption_set_ids.smithdb_cache == "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/platform-rg/providers/Microsoft.Compute/diskEncryptionSets/des-smithdb"
    error_message = "The cache StorageClass should name its own set, got ${jsonencode(module.k8s_bootstrap.storage_class_disk_encryption_set_ids.smithdb_cache)}"
  }

  assert {
    condition     = module.k8s_bootstrap.storage_class_disk_encryption_set_ids.sandbox_juicefs_redis == "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/platform-rg/providers/Microsoft.Compute/diskEncryptionSets/des-sandbox"
    error_message = "The JuiceFS Redis StorageClass should name its own set, got ${jsonencode(module.k8s_bootstrap.storage_class_disk_encryption_set_ids.sandbox_juicefs_redis)}"
  }

  assert {
    condition     = length(module.aks.additional_disk_encryption_set_reader_scopes) == 3 && toset([for s in module.aks.additional_disk_encryption_set_reader_scopes : lower(s)]) == toset([for n in ["des-smithdb", "des-sandbox", "des-clickhouse"] : lower("/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/platform-rg/providers/Microsoft.Compute/diskEncryptionSets/${n}")])
    error_message = "There should be one Reader assignment per distinct further set (cache, sandbox, clickhouse), got ${jsonencode(module.aks.additional_disk_encryption_set_reader_scopes)}"
  }
}

run "further_sets_get_no_grant_without_the_flag" {
  command = plan

  variables {
    aks_additional_disk_encryption_set_ids = ["/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/platform-rg/providers/Microsoft.Compute/diskEncryptionSets/des-clickhouse"]
  }

  assert {
    condition     = length(module.aks.additional_disk_encryption_set_reader_scopes) == 0 && module.aks.disk_encryption_set_reader_scope == null
    error_message = "Without aks_additional_disk_encryption_set_reader_grant no Reader assignment should be planned"
  }
}

run "the_further_grant_needs_only_a_further_set" {
  command = plan

  variables {
    aks_additional_disk_encryption_set_ids          = ["/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/platform-rg/providers/Microsoft.Compute/diskEncryptionSets/des-clickhouse"]
    aks_additional_disk_encryption_set_reader_grant = true
  }

  assert {
    condition     = length(module.aks.additional_disk_encryption_set_reader_scopes) == 1 && module.aks.disk_encryption_set_reader_scope == null
    error_message = "With no cluster set, only the further set should get a Reader assignment"
  }
}

run "refuses_a_metastore_key_that_is_not_a_key_url" {
  command = plan

  variables {
    enable_smithdb                                     = true
    smithdb_metastore_customer_managed_key_id          = "https://kv-smithdb.vault.azure.net/secrets/metastore"
    smithdb_metastore_customer_managed_key_identity_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/platform-rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-metastore"
  }

  expect_failures = [var.smithdb_metastore_customer_managed_key_id]
}

run "refuses_a_metastore_key_without_its_identity" {
  command = plan

  variables {
    enable_smithdb                            = true
    smithdb_metastore_customer_managed_key_id = "https://kv-smithdb.vault.azure.net/keys/metastore"
  }

  expect_failures = [var.smithdb_metastore_customer_managed_key_id]
}

run "refuses_a_storage_identity_that_is_not_an_identity" {
  command = plan

  variables {
    enable_smithdb                                   = true
    smithdb_storage_customer_managed_key_id          = "https://kv-smithdb.vault.azure.net/keys/smithdb-storage"
    smithdb_storage_customer_managed_key_identity_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/platform-rg/providers/Microsoft.KeyVault/vaults/kv-smithdb"
  }

  expect_failures = [var.smithdb_storage_customer_managed_key_identity_id]
}

run "refuses_a_storage_key_without_smithdb" {
  command = plan

  variables {
    smithdb_storage_customer_managed_key_id          = "https://kv-smithdb.vault.azure.net/keys/smithdb-storage"
    smithdb_storage_customer_managed_key_identity_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/platform-rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-smithdb-storage"
  }

  expect_failures = [var.smithdb_storage_customer_managed_key_id]
}

run "refuses_a_cache_set_that_is_not_a_set" {
  command = plan

  variables {
    enable_smithdb                       = true
    smithdb_cache_disk_encryption_set_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/platform-rg/providers/Microsoft.KeyVault/vaults/kv-smithdb"
  }

  expect_failures = [var.smithdb_cache_disk_encryption_set_id]
}

run "refuses_a_sandbox_set_without_an_in_cluster_redis" {
  command = plan

  variables {
    sandbox_juicefs_redis_disk_encryption_set_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/platform-rg/providers/Microsoft.Compute/diskEncryptionSets/des-sandbox"
  }

  expect_failures = [var.sandbox_juicefs_redis_disk_encryption_set_id]
}

run "refuses_a_further_set_that_is_not_a_set" {
  command = plan

  variables {
    aks_additional_disk_encryption_set_ids = ["des-clickhouse"]
  }

  expect_failures = [var.aks_additional_disk_encryption_set_ids]
}

run "the_cluster_grant_leaves_owner_granted_further_sets_alone" {
  command = plan

  variables {
    aks_disk_encryption_set_id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/platform-rg/providers/Microsoft.Compute/diskEncryptionSets/des-cluster"
    aks_disk_encryption_set_reader_grant = true
    enable_smithdb                       = true
    smithdb_cache_disk_encryption_set_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/platform-rg/providers/Microsoft.Compute/diskEncryptionSets/des-smithdb"
  }

  assert {
    condition     = module.aks.disk_encryption_set_reader_scope != null && length(module.aks.additional_disk_encryption_set_reader_scopes) == 0
    error_message = "The cluster set's grant should not grant the per-store sets, got ${jsonencode(module.aks.additional_disk_encryption_set_reader_scopes)}"
  }
}

run "refuses_the_further_grant_with_no_further_set" {
  command = plan

  variables {
    aks_additional_disk_encryption_set_reader_grant = true
  }

  expect_failures = [var.aks_additional_disk_encryption_set_reader_grant]
}
