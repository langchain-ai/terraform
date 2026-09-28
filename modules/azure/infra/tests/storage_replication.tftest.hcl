# Storage redundancy: the two variables reach their accounts, and the guard
# refuses a change that adds or removes zone redundancy on an account Azure
# already has, because the provider would apply it by deleting and recreating
# the account. The guard reads the live SKU from a subscription-wide account
# list; each run that needs an existing account stubs that list with
# override_data. Fixed names (unique_resource_names = false, name_prefix =
# "test") make the account names predictable: the trace-blob account is
# langsmithblobtest in langsmith-rg-test.

mock_provider "azurerm" {
  mock_data "azurerm_client_config" {
    defaults = {
      tenant_id       = "00000000-0000-0000-0000-000000000000"
      client_id       = "00000000-0000-0000-0000-000000000000"
      object_id       = "11111111-1111-1111-1111-111111111111"
      subscription_id = "00000000-0000-0000-0000-000000000000"
    }
  }
}
# Both azapi lists (clusters here, storage accounts in the root) take this
# default unless a run overrides one.
mock_provider "azapi" {
  mock_data "azapi_resource_list" {
    defaults = {
      output = { clusters = [], accounts = [] }
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
  name_prefix             = "test"
  unique_resource_names   = false
}

# ── Wiring ───────────────────────────────────────────────────────────────────

run "replication_defaults_to_lrs" {
  command = plan

  variables {
    storage_replication_type = "LRS"
  }

  assert {
    condition     = module.blob.replication_type == "LRS"
    error_message = "storage_replication_type = LRS did not reach the trace-blob account"
  }
}

run "zrs_reaches_a_new_account" {
  command = plan

  variables {
    storage_replication_type = "ZRS"
  }

  assert {
    condition     = module.blob.replication_type == "ZRS"
    error_message = "storage_replication_type = ZRS did not reach the trace-blob account"
  }
}

# ── Guard ────────────────────────────────────────────────────────────────────

run "lrs_to_zrs_on_an_existing_account_is_refused" {
  command = plan

  variables {
    storage_replication_type = "ZRS"
  }

  override_data {
    target = data.azapi_resource_list.storage_accounts
    values = {
      output = {
        accounts = [{
          id   = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/langsmith-rg-test/providers/Microsoft.Storage/storageAccounts/langsmithblobtest"
          name = "langsmithblobtest"
          sku  = "Standard_LRS"
        }]
      }
    }
  }

  expect_failures = [terraform_data.storage_replication_guard]
}

run "zrs_to_lrs_on_an_existing_account_is_refused" {
  command = plan

  variables {
    storage_replication_type = "LRS"
  }

  override_data {
    target = data.azapi_resource_list.storage_accounts
    values = {
      output = {
        accounts = [{
          id   = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/langsmith-rg-test/providers/Microsoft.Storage/storageAccounts/langsmithblobtest"
          name = "langsmithblobtest"
          sku  = "Standard_ZRS"
        }]
      }
    }
  }

  expect_failures = [terraform_data.storage_replication_guard]
}

# LRS to GRS adds geo-redundancy without touching zones: the provider updates
# it in place, so the guard lets it through.
run "lrs_to_grs_on_an_existing_account_passes" {
  command = plan

  variables {
    storage_replication_type = "GRS"
  }

  override_data {
    target = data.azapi_resource_list.storage_accounts
    values = {
      output = {
        accounts = [{
          id   = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/langsmith-rg-test/providers/Microsoft.Storage/storageAccounts/langsmithblobtest"
          name = "langsmithblobtest"
          sku  = "Standard_LRS"
        }]
      }
    }
  }

  assert {
    condition     = module.blob.replication_type == "GRS"
    error_message = "LRS to GRS on an existing account did not pass the guard"
  }
}

# After Azure's conversion the live SKU already matches, so the plan is clean.
run "converted_account_matching_the_variable_passes" {
  command = plan

  variables {
    storage_replication_type = "ZRS"
  }

  override_data {
    target = data.azapi_resource_list.storage_accounts
    values = {
      output = {
        accounts = [{
          id   = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/langsmith-rg-test/providers/Microsoft.Storage/storageAccounts/langsmithblobtest"
          name = "langsmithblobtest"
          sku  = "Standard_ZRS"
        }]
      }
    }
  }

  assert {
    condition     = module.blob.replication_type == "ZRS"
    error_message = "a ZRS account with storage_replication_type = ZRS was refused"
  }
}

# An account of the same name in another resource group is someone else's.
run "same_name_in_another_resource_group_is_ignored" {
  command = plan

  variables {
    storage_replication_type = "ZRS"
  }

  override_data {
    target = data.azapi_resource_list.storage_accounts
    values = {
      output = {
        accounts = [{
          id   = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/other-rg/providers/Microsoft.Storage/storageAccounts/langsmithblobtest"
          name = "langsmithblobtest"
          sku  = "Standard_LRS"
        }]
      }
    }
  }

  assert {
    condition     = module.blob.replication_type == "ZRS"
    error_message = "an account in another resource group tripped the guard"
  }
}

# ── Validation ───────────────────────────────────────────────────────────────

run "replication_rejects_an_unknown_value" {
  command = plan

  variables {
    storage_replication_type         = "Premium_LRS"
    smithdb_storage_replication_type = "zrs"
  }

  expect_failures = [
    var.storage_replication_type,
    var.smithdb_storage_replication_type,
  ]
}

run "smithdb_replication_reaches_its_account" {
  command = plan

  variables {
    enable_smithdb                   = true
    availability_zones               = ["1", "2", "3"]
    smithdb_storage_replication_type = "ZRS"
  }

  assert {
    condition     = module.smithdb[0].storage_replication_type == "ZRS"
    error_message = "smithdb_storage_replication_type did not reach the SmithDB account"
  }
}

run "smithdb_zone_change_on_an_existing_account_is_refused" {
  command = plan

  variables {
    enable_smithdb                   = true
    availability_zones               = ["1", "2", "3"]
    smithdb_storage_replication_type = "ZRS"
  }

  override_data {
    target = data.azapi_resource_list.storage_accounts
    values = {
      output = {
        accounts = [{
          id   = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/langsmith-rg-test/providers/Microsoft.Storage/storageAccounts/langsmithsmithdbtest"
          name = "langsmithsmithdbtest"
          sku  = "Standard_LRS"
        }]
      }
    }
  }

  expect_failures = [terraform_data.storage_replication_guard]
}

# An existing deployment turning SmithDB on: the trace-blob account exists at LRS
# and the SmithDB account does not exist yet, so nothing is changing zones.
run "existing_deployment_turning_smithdb_on_plans_clean" {
  command = plan

  variables {
    enable_smithdb                   = true
    availability_zones               = ["1", "2", "3"]
    storage_replication_type         = "LRS"
    smithdb_storage_replication_type = "ZRS"
  }

  override_data {
    target = data.azapi_resource_list.storage_accounts
    values = {
      output = {
        accounts = [{
          id   = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/langsmith-rg-test/providers/Microsoft.Storage/storageAccounts/langsmithblobtest"
          name = "langsmithblobtest"
          sku  = "Standard_LRS"
        }]
      }
    }
  }

  assert {
    condition     = module.smithdb[0].storage_replication_type == "ZRS" && module.blob.replication_type == "LRS"
    error_message = "turning SmithDB on beside an existing LRS trace-blob account did not plan clean"
  }
}

# LRS to GZRS changes both parts, which Azure does in two steps; the guard still
# refuses it on an existing account (and its message names ZRS as the first step).
run "lrs_to_gzrs_on_an_existing_account_is_refused" {
  command = plan

  variables {
    storage_replication_type = "GZRS"
  }

  override_data {
    target = data.azapi_resource_list.storage_accounts
    values = {
      output = {
        accounts = [{
          id   = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/langsmith-rg-test/providers/Microsoft.Storage/storageAccounts/langsmithblobtest"
          name = "langsmithblobtest"
          sku  = "Standard_LRS"
        }]
      }
    }
  }

  expect_failures = [terraform_data.storage_replication_guard]
}
